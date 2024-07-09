defmodule Electric.ShapeCache.CubDbStorage do
  alias Electric.Replication.Changes
  alias Electric.Postgres.Lsn
  alias Electric.Utils
  @behaviour Electric.ShapeCache.Storage

  @snapshot_offset 0
  @snapshot_key_type 0
  @log_key_type 1

  def shared_opts(opts) do
    file_path = Access.get(opts, :file_path, "./shapes")
    db = Access.get(opts, :db, :shape_db)

    {:ok, %{file_path: file_path, db: db}}
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(opts) do
    File.mkdir_p(opts.file_path)
    CubDB.start_link(data_dir: opts.file_path, name: opts.db)
  end

  def snapshot_exists?(shape_id, opts) do
    CubDB.has_key?(opts.db, snapshot_start(shape_id))
  end

  def get_snapshot(shape_id, opts) do
    results =
      opts.db
      |> CubDB.select(
        min_key: snapshot_start(shape_id),
        max_key: snapshot_end(shape_id)
      )
      |> Stream.map(&storage_item_to_log_item/1)
      |> Enum.to_list()

    {@snapshot_offset, results}
  end

  def get_log_stream(shape_id, offset, size \\ :infinity, opts) do
    opts.db
    |> CubDB.select(
      min_key: log_key(shape_id, offset + 1),
      max_key: log_end(shape_id)
    )
    |> Stream.map(&storage_item_to_log_item/1)
    |> limit_stream(size)
  end

  def has_log_entry?(shape_id, offset, opts) do
    CubDB.has_key?(opts.db, log_key(shape_id, offset))
  end

  def make_new_snapshot!(shape_id, query_info, data_stream, opts) do
    data_stream
    |> Stream.with_index()
    |> Stream.map(&row_to_snapshot_item(&1, shape_id, query_info))
    |> Stream.chunk_every(500)
    |> Stream.each(fn chunk -> CubDB.put_multi(opts.db, chunk) end)
    |> Stream.run()
  end

  def append_to_log!(shape_id, lsn, xid, changes, opts) do
    base_offset = Lsn.to_integer(lsn)

    changes
    |> Enum.with_index(fn
      %{relation: _} = change, index ->
        change_key = Changes.build_key(change)
        value = Changes.to_json_value(change)
        action = Changes.get_action(change)
        {log_key(shape_id, base_offset + index), {xid, change_key, action, value}}
    end)
    |> then(&CubDB.put_multi(opts.db, &1))

    :ok
  end

  def cleanup!(shape_id, opts) do
    # Deletes from the snapshot start to the log end
    # and since @snapshot_key_type < @log_key_type this will
    # delete everything for the shape.
    CubDB.select(opts.db,
      min_key: snapshot_start(shape_id),
      max_key: log_end(shape_id)
    )
    |> Enum.each(fn {key, _} -> CubDB.delete(opts.db, key) end)
  end

  defp snapshot_key(shape_id, index) do
    {shape_id, @snapshot_key_type, index}
  end

  defp log_key(shape_id, offset) do
    {shape_id, @log_key_type, offset}
  end

  defp offset({_shape_id, @snapshot_key_type, _index}), do: @snapshot_offset
  defp offset({_shape_id, @log_key_type, offset}), do: offset

  defp log_end(shape_id) do
    log_key(shape_id, :end)
  end

  defp snapshot_start(shape_id) do
    snapshot_key(shape_id, 0)
  end

  defp snapshot_end(shape_id) do
    snapshot_key(shape_id, :end)
  end

  defp row_to_snapshot_item({row, index}, shape_id, %Postgrex.Query{
         name: change_key_prefix,
         columns: columns,
         result_types: types
       }) do
    serialized_row =
      [columns, types, row]
      |> Enum.zip_with(fn
        [col, Postgrex.Extensions.UUID, val] -> {col, Utils.encode_uuid(val)}
        [col, _, val] -> {col, val}
      end)
      |> Map.new()

    # FIXME: This should not assume pk columns, but we're not querying PG for that info yet
    pk = Map.fetch!(serialized_row, "id")
    change_key = "#{change_key_prefix}/#{pk}"

    {snapshot_key(shape_id, index), {_xid = nil, change_key, "insert", serialized_row}}
  end

  defp storage_item_to_log_item({key, {xid, change_key, action, value}}) do
    %{key: change_key, value: value, headers: headers(action, xid), offset: offset(key)}
  end

  defp headers(action, nil = _xid), do: %{action: action}
  defp headers(action, xid), do: %{action: action, txid: xid}

  defp limit_stream(stream, :infinity), do: stream
  defp limit_stream(stream, size), do: Stream.take(stream, size)
end