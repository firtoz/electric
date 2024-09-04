import { describe, expectTypeOf, it } from 'vitest'
import {
  Row,
  ShapeStream,
  Shape,
  Message,
  isChangeMessage,
  ShapeData,
} from '../src'

type CustomRow = {
  foo: number
  bar: boolean
  baz: string
}

describe(`client`, () => {
  describe(`ShapeStream`, () => {
    it(`should infer generic row return type when no type is provided`, () => {
      const shapeStream = new ShapeStream({
        url: ``,
      })

      expectTypeOf(shapeStream).toEqualTypeOf<ShapeStream<Row>>()
      shapeStream.subscribe((msgs) => {
        expectTypeOf(msgs).toEqualTypeOf<Message<Row>[]>()
      })
    })

    it(`should infer correct return type when provided`, () => {
      const shapeStream = new ShapeStream<CustomRow>({
        url: ``,
      })

      shapeStream.subscribe((msgs) => {
        expectTypeOf(msgs).toEqualTypeOf<Message<CustomRow>[]>()
        if (isChangeMessage(msgs[0])) {
          expectTypeOf(msgs[0].value).toEqualTypeOf<CustomRow>()
        }
      })
    })
  })

  describe(`Shape`, () => {
    it(`should infer generic row return type when no type is provided`, async () => {
      const shapeStream = new ShapeStream({
        url: ``,
      })
      const shape = new Shape(shapeStream)

      expectTypeOf(shape).toEqualTypeOf<Shape<Row>>()

      shape.subscribe((data) => {
        expectTypeOf(data).toEqualTypeOf<ShapeData<Row>>()
      })

      const data = await shape.value
      expectTypeOf(data).toEqualTypeOf<ShapeData<Row>>()
    })

    it(`should infer correct return type when provided`, async () => {
      const shapeStream = new ShapeStream<CustomRow>({
        url: ``,
      })
      const shape = new Shape(shapeStream)
      expectTypeOf(shape).toEqualTypeOf<Shape<CustomRow>>()

      shape.subscribe((data) => {
        expectTypeOf(data).toEqualTypeOf<ShapeData<CustomRow>>()
      })

      const data = await shape.value
      expectTypeOf(data).toEqualTypeOf<ShapeData<CustomRow>>()
    })
  })
})