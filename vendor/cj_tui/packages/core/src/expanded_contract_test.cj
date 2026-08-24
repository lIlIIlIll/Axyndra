package core

import std.unittest.*
import std.unittest.testmacro.*

@Test
class CjTuiExpandedContractTest {
    @TestCase
    func displayWidthAsciiA(): Unit {
        @Expect(displayWidth("a"), 1)
    }

    @TestCase
    func displayWidthAsciiWord(): Unit {
        @Expect(displayWidth("abc"), 3)
    }

    @TestCase
    func displayWidthEmpty(): Unit {
        @Expect(displayWidth(""), 0)
    }

    @TestCase
    func displayWidthSpace(): Unit {
        @Expect(displayWidth(" "), 1)
    }

    @TestCase
    func displayWidthTab(): Unit {
        @Expect(displayWidth("\t"), 0)
    }

    @TestCase
    func displayWidthNewline(): Unit {
        @Expect(displayWidth("\n"), 0)
    }

    @TestCase
    func displayWidthCjkOne(): Unit {
        @Expect(displayWidth("界"), 2)
    }

    @TestCase
    func displayWidthCjkTwo(): Unit {
        @Expect(displayWidth("界面"), 4)
    }

    @TestCase
    func displayWidthMixed(): Unit {
        @Expect(displayWidth("a界b"), 4)
    }

    @TestCase
    func displayWidthCombining(): Unit {
        @Expect(displayWidth("e\u{0301}"), 1)
    }

    @TestCase
    func displayWidthVariation(): Unit {
        @Expect(displayWidth("\u{2764}\u{FE0F}"), 1)
    }

    @TestCase
    func displayWidthEmoji(): Unit {
        @Expect(displayWidth("\u{1F600}"), 2)
    }

    @TestCase
    func displayWidthFullwidth(): Unit {
        @Expect(displayWidth("Ａ"), 2)
    }

    @TestCase
    func displayWidthHangul(): Unit {
        @Expect(displayWidth("가"), 2)
    }

    @TestCase
    func displayWidthKana(): Unit {
        @Expect(displayWidth("カ"), 2)
    }

    @TestCase
    func displayWidthAsciiRepeated0(): Unit {
        @Expect(displayWidth("x"), 1)
    }

    @TestCase
    func displayWidthAsciiRepeated1(): Unit {
        @Expect(displayWidth("xx"), 2)
    }

    @TestCase
    func displayWidthAsciiRepeated2(): Unit {
        @Expect(displayWidth("xxx"), 3)
    }

    @TestCase
    func displayWidthAsciiRepeated3(): Unit {
        @Expect(displayWidth("xxxx"), 4)
    }

    @TestCase
    func displayWidthAsciiRepeated4(): Unit {
        @Expect(displayWidth("xxxxx"), 5)
    }

    @TestCase
    func displayWidthAsciiRepeated5(): Unit {
        @Expect(displayWidth("xxxxxx"), 6)
    }

    @TestCase
    func displayWidthAsciiRepeated6(): Unit {
        @Expect(displayWidth("xxxxxxx"), 7)
    }

    @TestCase
    func displayWidthAsciiRepeated7(): Unit {
        @Expect(displayWidth("xxxxxxxx"), 8)
    }

    @TestCase
    func displayWidthAsciiRepeated8(): Unit {
        @Expect(displayWidth("xxxxxxxxx"), 9)
    }

    @TestCase
    func displayWidthAsciiRepeated9(): Unit {
        @Expect(displayWidth("xxxxxxxxxx"), 10)
    }

    @TestCase
    func displayWidthAsciiRepeated10(): Unit {
        @Expect(displayWidth("x"), 1)
    }

    @TestCase
    func displayWidthAsciiRepeated11(): Unit {
        @Expect(displayWidth("xx"), 2)
    }

    @TestCase
    func displayWidthAsciiRepeated12(): Unit {
        @Expect(displayWidth("xxx"), 3)
    }

    @TestCase
    func displayWidthAsciiRepeated13(): Unit {
        @Expect(displayWidth("xxxx"), 4)
    }

    @TestCase
    func displayWidthAsciiRepeated14(): Unit {
        @Expect(displayWidth("xxxxx"), 5)
    }

    @TestCase
    func displayWidthAsciiRepeated15(): Unit {
        @Expect(displayWidth("xxxxxx"), 6)
    }

    @TestCase
    func displayWidthAsciiRepeated16(): Unit {
        @Expect(displayWidth("xxxxxxx"), 7)
    }

    @TestCase
    func displayWidthAsciiRepeated17(): Unit {
        @Expect(displayWidth("xxxxxxxx"), 8)
    }

    @TestCase
    func displayWidthAsciiRepeated18(): Unit {
        @Expect(displayWidth("xxxxxxxxx"), 9)
    }

    @TestCase
    func displayWidthAsciiRepeated19(): Unit {
        @Expect(displayWidth("xxxxxxxxxx"), 10)
    }

    @TestCase
    func displayWidthAsciiRepeated20(): Unit {
        @Expect(displayWidth("x"), 1)
    }

    @TestCase
    func displayWidthAsciiRepeated21(): Unit {
        @Expect(displayWidth("xx"), 2)
    }

    @TestCase
    func displayWidthAsciiRepeated22(): Unit {
        @Expect(displayWidth("xxx"), 3)
    }

    @TestCase
    func displayWidthAsciiRepeated23(): Unit {
        @Expect(displayWidth("xxxx"), 4)
    }

    @TestCase
    func displayWidthAsciiRepeated24(): Unit {
        @Expect(displayWidth("xxxxx"), 5)
    }

    @TestCase
    func displayWidthAsciiRepeated25(): Unit {
        @Expect(displayWidth("xxxxxx"), 6)
    }

    @TestCase
    func displayWidthAsciiRepeated26(): Unit {
        @Expect(displayWidth("xxxxxxx"), 7)
    }

    @TestCase
    func displayWidthAsciiRepeated27(): Unit {
        @Expect(displayWidth("xxxxxxxx"), 8)
    }

    @TestCase
    func displayWidthAsciiRepeated28(): Unit {
        @Expect(displayWidth("xxxxxxxxx"), 9)
    }

    @TestCase
    func displayWidthAsciiRepeated29(): Unit {
        @Expect(displayWidth("xxxxxxxxxx"), 10)
    }

    @TestCase
    func rectPropsCase0(): Unit {
        let rect = Rect(0, 1, 2, 3)
        @Expect(rect.right, 2)
        @Expect(rect.bottom, 4)
    }

    @TestCase
    func rectPropsCase1(): Unit {
        let rect = Rect(1, 2, 3, 4)
        @Expect(rect.right, 4)
        @Expect(rect.bottom, 6)
    }

    @TestCase
    func rectPropsCase2(): Unit {
        let rect = Rect(2, 3, 4, 5)
        @Expect(rect.right, 6)
        @Expect(rect.bottom, 8)
    }

    @TestCase
    func rectPropsCase3(): Unit {
        let rect = Rect(3, 4, 5, 6)
        @Expect(rect.right, 8)
        @Expect(rect.bottom, 10)
    }

    @TestCase
    func rectPropsCase4(): Unit {
        let rect = Rect(4, 5, 6, 7)
        @Expect(rect.right, 10)
        @Expect(rect.bottom, 12)
    }

    @TestCase
    func rectPropsCase5(): Unit {
        let rect = Rect(5, 6, 7, 8)
        @Expect(rect.right, 12)
        @Expect(rect.bottom, 14)
    }

    @TestCase
    func rectPropsCase6(): Unit {
        let rect = Rect(6, 7, 8, 9)
        @Expect(rect.right, 14)
        @Expect(rect.bottom, 16)
    }

    @TestCase
    func rectPropsCase7(): Unit {
        let rect = Rect(7, 8, 9, 10)
        @Expect(rect.right, 16)
        @Expect(rect.bottom, 18)
    }

    @TestCase
    func rectPropsCase8(): Unit {
        let rect = Rect(8, 9, 10, 11)
        @Expect(rect.right, 18)
        @Expect(rect.bottom, 20)
    }

    @TestCase
    func rectPropsCase9(): Unit {
        let rect = Rect(9, 10, 11, 12)
        @Expect(rect.right, 20)
        @Expect(rect.bottom, 22)
    }

    @TestCase
    func rectPropsCase10(): Unit {
        let rect = Rect(10, 11, 12, 13)
        @Expect(rect.right, 22)
        @Expect(rect.bottom, 24)
    }

    @TestCase
    func rectPropsCase11(): Unit {
        let rect = Rect(11, 12, 13, 14)
        @Expect(rect.right, 24)
        @Expect(rect.bottom, 26)
    }

    @TestCase
    func rectPropsCase12(): Unit {
        let rect = Rect(12, 13, 14, 15)
        @Expect(rect.right, 26)
        @Expect(rect.bottom, 28)
    }

    @TestCase
    func rectPropsCase13(): Unit {
        let rect = Rect(13, 14, 15, 16)
        @Expect(rect.right, 28)
        @Expect(rect.bottom, 30)
    }

    @TestCase
    func rectPropsCase14(): Unit {
        let rect = Rect(14, 15, 16, 17)
        @Expect(rect.right, 30)
        @Expect(rect.bottom, 32)
    }

    @TestCase
    func rectPropsCase15(): Unit {
        let rect = Rect(15, 16, 17, 18)
        @Expect(rect.right, 32)
        @Expect(rect.bottom, 34)
    }

    @TestCase
    func rectPropsCase16(): Unit {
        let rect = Rect(16, 17, 18, 19)
        @Expect(rect.right, 34)
        @Expect(rect.bottom, 36)
    }

    @TestCase
    func rectPropsCase17(): Unit {
        let rect = Rect(17, 18, 19, 20)
        @Expect(rect.right, 36)
        @Expect(rect.bottom, 38)
    }

    @TestCase
    func rectPropsCase18(): Unit {
        let rect = Rect(18, 19, 20, 21)
        @Expect(rect.right, 38)
        @Expect(rect.bottom, 40)
    }

    @TestCase
    func rectPropsCase19(): Unit {
        let rect = Rect(19, 20, 21, 22)
        @Expect(rect.right, 40)
        @Expect(rect.bottom, 42)
    }

    @TestCase
    func rectClampsNegativeSize0(): Unit {
        let rect = Rect(0, 0, -1, -2)
        @Expect(rect.width, 0)
        @Expect(rect.height, 0)
    }

    @TestCase
    func rectClampsNegativeSize1(): Unit {
        let rect = Rect(1, 1, -2, -3)
        @Expect(rect.width, 0)
        @Expect(rect.height, 0)
    }

    @TestCase
    func rectClampsNegativeSize2(): Unit {
        let rect = Rect(2, 2, -3, -4)
        @Expect(rect.width, 0)
        @Expect(rect.height, 0)
    }

    @TestCase
    func rectClampsNegativeSize3(): Unit {
        let rect = Rect(3, 3, -4, -5)
        @Expect(rect.width, 0)
        @Expect(rect.height, 0)
    }

    @TestCase
    func rectClampsNegativeSize4(): Unit {
        let rect = Rect(4, 4, -5, -6)
        @Expect(rect.width, 0)
        @Expect(rect.height, 0)
    }

    @TestCase
    func rectClampsNegativeSize5(): Unit {
        let rect = Rect(5, 5, -6, -7)
        @Expect(rect.width, 0)
        @Expect(rect.height, 0)
    }

    @TestCase
    func rectClampsNegativeSize6(): Unit {
        let rect = Rect(6, 6, -7, -8)
        @Expect(rect.width, 0)
        @Expect(rect.height, 0)
    }

    @TestCase
    func rectClampsNegativeSize7(): Unit {
        let rect = Rect(7, 7, -8, -9)
        @Expect(rect.width, 0)
        @Expect(rect.height, 0)
    }

    @TestCase
    func rectClampsNegativeSize8(): Unit {
        let rect = Rect(8, 8, -9, -10)
        @Expect(rect.width, 0)
        @Expect(rect.height, 0)
    }

    @TestCase
    func rectClampsNegativeSize9(): Unit {
        let rect = Rect(9, 9, -10, -11)
        @Expect(rect.width, 0)
        @Expect(rect.height, 0)
    }

    @TestCase
    func spacingInnerCase0(): Unit {
        let inner = Spacing(left: 0, right: 1, top: 2, bottom: 0).inner(Rect(10, 20, 30, 40))
        @Expect(inner.x, 10)
        @Expect(inner.y, 22)
        @Expect(inner.width, 29)
        @Expect(inner.height, 38)
    }

    @TestCase
    func spacingInnerCase1(): Unit {
        let inner = Spacing(left: 1, right: 2, top: 0, bottom: 1).inner(Rect(10, 20, 30, 40))
        @Expect(inner.x, 11)
        @Expect(inner.y, 20)
        @Expect(inner.width, 27)
        @Expect(inner.height, 39)
    }

    @TestCase
    func spacingInnerCase2(): Unit {
        let inner = Spacing(left: 2, right: 3, top: 1, bottom: 2).inner(Rect(10, 20, 30, 40))
        @Expect(inner.x, 12)
        @Expect(inner.y, 21)
        @Expect(inner.width, 25)
        @Expect(inner.height, 37)
    }

    @TestCase
    func spacingInnerCase3(): Unit {
        let inner = Spacing(left: 3, right: 0, top: 2, bottom: 0).inner(Rect(10, 20, 30, 40))
        @Expect(inner.x, 13)
        @Expect(inner.y, 22)
        @Expect(inner.width, 27)
        @Expect(inner.height, 38)
    }

    @TestCase
    func spacingInnerCase4(): Unit {
        let inner = Spacing(left: 0, right: 1, top: 0, bottom: 1).inner(Rect(10, 20, 30, 40))
        @Expect(inner.x, 10)
        @Expect(inner.y, 20)
        @Expect(inner.width, 29)
        @Expect(inner.height, 39)
    }

    @TestCase
    func spacingInnerCase5(): Unit {
        let inner = Spacing(left: 1, right: 2, top: 1, bottom: 2).inner(Rect(10, 20, 30, 40))
        @Expect(inner.x, 11)
        @Expect(inner.y, 21)
        @Expect(inner.width, 27)
        @Expect(inner.height, 37)
    }

    @TestCase
    func spacingInnerCase6(): Unit {
        let inner = Spacing(left: 2, right: 3, top: 2, bottom: 0).inner(Rect(10, 20, 30, 40))
        @Expect(inner.x, 12)
        @Expect(inner.y, 22)
        @Expect(inner.width, 25)
        @Expect(inner.height, 38)
    }

    @TestCase
    func spacingInnerCase7(): Unit {
        let inner = Spacing(left: 3, right: 0, top: 0, bottom: 1).inner(Rect(10, 20, 30, 40))
        @Expect(inner.x, 13)
        @Expect(inner.y, 20)
        @Expect(inner.width, 27)
        @Expect(inner.height, 39)
    }

    @TestCase
    func spacingInnerCase8(): Unit {
        let inner = Spacing(left: 0, right: 1, top: 1, bottom: 2).inner(Rect(10, 20, 30, 40))
        @Expect(inner.x, 10)
        @Expect(inner.y, 21)
        @Expect(inner.width, 29)
        @Expect(inner.height, 37)
    }

    @TestCase
    func spacingInnerCase9(): Unit {
        let inner = Spacing(left: 1, right: 2, top: 2, bottom: 0).inner(Rect(10, 20, 30, 40))
        @Expect(inner.x, 11)
        @Expect(inner.y, 22)
        @Expect(inner.width, 27)
        @Expect(inner.height, 38)
    }

    @TestCase
    func spacingInnerCase10(): Unit {
        let inner = Spacing(left: 2, right: 3, top: 0, bottom: 1).inner(Rect(10, 20, 30, 40))
        @Expect(inner.x, 12)
        @Expect(inner.y, 20)
        @Expect(inner.width, 25)
        @Expect(inner.height, 39)
    }

    @TestCase
    func spacingInnerCase11(): Unit {
        let inner = Spacing(left: 3, right: 0, top: 1, bottom: 2).inner(Rect(10, 20, 30, 40))
        @Expect(inner.x, 13)
        @Expect(inner.y, 21)
        @Expect(inner.width, 27)
        @Expect(inner.height, 37)
    }

    @TestCase
    func spacingInnerCase12(): Unit {
        let inner = Spacing(left: 0, right: 1, top: 2, bottom: 0).inner(Rect(10, 20, 30, 40))
        @Expect(inner.x, 10)
        @Expect(inner.y, 22)
        @Expect(inner.width, 29)
        @Expect(inner.height, 38)
    }

    @TestCase
    func spacingInnerCase13(): Unit {
        let inner = Spacing(left: 1, right: 2, top: 0, bottom: 1).inner(Rect(10, 20, 30, 40))
        @Expect(inner.x, 11)
        @Expect(inner.y, 20)
        @Expect(inner.width, 27)
        @Expect(inner.height, 39)
    }

    @TestCase
    func spacingInnerCase14(): Unit {
        let inner = Spacing(left: 2, right: 3, top: 1, bottom: 2).inner(Rect(10, 20, 30, 40))
        @Expect(inner.x, 12)
        @Expect(inner.y, 21)
        @Expect(inner.width, 25)
        @Expect(inner.height, 37)
    }

    @TestCase
    func bufferSetStringAsciiCase0(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(0, 0, "abc")
        @Expect(buffer.getCell(0, 0).symbol, "a")
        @Expect(buffer.getCell(1, 0).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase1(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(1, 1, "abc")
        @Expect(buffer.getCell(1, 1).symbol, "a")
        @Expect(buffer.getCell(2, 1).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase2(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(2, 0, "abc")
        @Expect(buffer.getCell(2, 0).symbol, "a")
        @Expect(buffer.getCell(3, 0).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase3(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(3, 1, "abc")
        @Expect(buffer.getCell(3, 1).symbol, "a")
        @Expect(buffer.getCell(4, 1).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase4(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(4, 0, "abc")
        @Expect(buffer.getCell(4, 0).symbol, "a")
        @Expect(buffer.getCell(5, 0).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase5(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(0, 1, "abc")
        @Expect(buffer.getCell(0, 1).symbol, "a")
        @Expect(buffer.getCell(1, 1).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase6(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(1, 0, "abc")
        @Expect(buffer.getCell(1, 0).symbol, "a")
        @Expect(buffer.getCell(2, 0).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase7(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(2, 1, "abc")
        @Expect(buffer.getCell(2, 1).symbol, "a")
        @Expect(buffer.getCell(3, 1).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase8(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(3, 0, "abc")
        @Expect(buffer.getCell(3, 0).symbol, "a")
        @Expect(buffer.getCell(4, 0).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase9(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(4, 1, "abc")
        @Expect(buffer.getCell(4, 1).symbol, "a")
        @Expect(buffer.getCell(5, 1).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase10(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(0, 0, "abc")
        @Expect(buffer.getCell(0, 0).symbol, "a")
        @Expect(buffer.getCell(1, 0).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase11(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(1, 1, "abc")
        @Expect(buffer.getCell(1, 1).symbol, "a")
        @Expect(buffer.getCell(2, 1).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase12(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(2, 0, "abc")
        @Expect(buffer.getCell(2, 0).symbol, "a")
        @Expect(buffer.getCell(3, 0).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase13(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(3, 1, "abc")
        @Expect(buffer.getCell(3, 1).symbol, "a")
        @Expect(buffer.getCell(4, 1).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase14(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(4, 0, "abc")
        @Expect(buffer.getCell(4, 0).symbol, "a")
        @Expect(buffer.getCell(5, 0).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase15(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(0, 1, "abc")
        @Expect(buffer.getCell(0, 1).symbol, "a")
        @Expect(buffer.getCell(1, 1).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase16(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(1, 0, "abc")
        @Expect(buffer.getCell(1, 0).symbol, "a")
        @Expect(buffer.getCell(2, 0).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase17(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(2, 1, "abc")
        @Expect(buffer.getCell(2, 1).symbol, "a")
        @Expect(buffer.getCell(3, 1).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase18(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(3, 0, "abc")
        @Expect(buffer.getCell(3, 0).symbol, "a")
        @Expect(buffer.getCell(4, 0).symbol, "b")
    }

    @TestCase
    func bufferSetStringAsciiCase19(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 2))
        buffer.setString(4, 1, "abc")
        @Expect(buffer.getCell(4, 1).symbol, "a")
        @Expect(buffer.getCell(5, 1).symbol, "b")
    }

    @TestCase
    func bufferWideCellCase0(): Unit {
        let buffer = Buffer(Rect(0, 0, 8, 1))
        buffer.setString(0, 0, "界")
        @Expect(buffer.getCell(0, 0).symbol, "界")
        @Expect(buffer.getCell(1, 0).symbol, "")
    }

    @TestCase
    func bufferWideCellCase1(): Unit {
        let buffer = Buffer(Rect(0, 0, 8, 1))
        buffer.setString(1, 0, "界")
        @Expect(buffer.getCell(1, 0).symbol, "界")
        @Expect(buffer.getCell(2, 0).symbol, "")
    }

    @TestCase
    func bufferWideCellCase2(): Unit {
        let buffer = Buffer(Rect(0, 0, 8, 1))
        buffer.setString(2, 0, "界")
        @Expect(buffer.getCell(2, 0).symbol, "界")
        @Expect(buffer.getCell(3, 0).symbol, "")
    }

    @TestCase
    func bufferWideCellCase3(): Unit {
        let buffer = Buffer(Rect(0, 0, 8, 1))
        buffer.setString(0, 0, "界")
        @Expect(buffer.getCell(0, 0).symbol, "界")
        @Expect(buffer.getCell(1, 0).symbol, "")
    }

    @TestCase
    func bufferWideCellCase4(): Unit {
        let buffer = Buffer(Rect(0, 0, 8, 1))
        buffer.setString(1, 0, "界")
        @Expect(buffer.getCell(1, 0).symbol, "界")
        @Expect(buffer.getCell(2, 0).symbol, "")
    }

    @TestCase
    func bufferWideCellCase5(): Unit {
        let buffer = Buffer(Rect(0, 0, 8, 1))
        buffer.setString(2, 0, "界")
        @Expect(buffer.getCell(2, 0).symbol, "界")
        @Expect(buffer.getCell(3, 0).symbol, "")
    }

    @TestCase
    func bufferWideCellCase6(): Unit {
        let buffer = Buffer(Rect(0, 0, 8, 1))
        buffer.setString(0, 0, "界")
        @Expect(buffer.getCell(0, 0).symbol, "界")
        @Expect(buffer.getCell(1, 0).symbol, "")
    }

    @TestCase
    func bufferWideCellCase7(): Unit {
        let buffer = Buffer(Rect(0, 0, 8, 1))
        buffer.setString(1, 0, "界")
        @Expect(buffer.getCell(1, 0).symbol, "界")
        @Expect(buffer.getCell(2, 0).symbol, "")
    }

    @TestCase
    func bufferWideCellCase8(): Unit {
        let buffer = Buffer(Rect(0, 0, 8, 1))
        buffer.setString(2, 0, "界")
        @Expect(buffer.getCell(2, 0).symbol, "界")
        @Expect(buffer.getCell(3, 0).symbol, "")
    }

    @TestCase
    func bufferWideCellCase9(): Unit {
        let buffer = Buffer(Rect(0, 0, 8, 1))
        buffer.setString(0, 0, "界")
        @Expect(buffer.getCell(0, 0).symbol, "界")
        @Expect(buffer.getCell(1, 0).symbol, "")
    }

    @TestCase
    func bufferMixedUnicodeAndAsciiRuns(): Unit {
        let buffer = Buffer(Rect(0, 0, 32, 1))
        buffer.setString(0, 0, "╭─ ✓ Run cargo test")
        @Expect(buffer.getCell(0, 0).symbol, "╭")
        @Expect(buffer.getCell(3, 0).symbol, "✓")
        @Expect(buffer.getCell(5, 0).symbol, "R")
        @Expect(buffer.getCell(18, 0).symbol, "t")
    }

    @TestCase
    func bufferAsciiBaseKeepsCombiningMark(): Unit {
        let buffer = Buffer(Rect(0, 0, 8, 1))
        buffer.setString(0, 0, "abce\u{0301}x")
        @Expect(buffer.getCell(2, 0).symbol, "c")
        @Expect(buffer.getCell(3, 0).symbol, "e\u{0301}")
        @Expect(buffer.getCell(4, 0).symbol, "x")
    }

    @TestCase
    func bufferMixedWideAndAsciiRuns(): Unit {
        let buffer = Buffer(Rect(0, 0, 16, 1))
        buffer.setString(0, 0, "路径 src/main.cj")
        @Expect(buffer.getCell(0, 0).symbol, "路")
        @Expect(buffer.getCell(1, 0).symbol, "")
        @Expect(buffer.getCell(4, 0).symbol, " ")
        @Expect(buffer.getCell(5, 0).symbol, "s")
    }

    @TestCase
    func bufferIndexOutOfBoundsCase0(): Unit {
        let buffer = Buffer(Rect(2, 3, 4, 5))
        match (buffer.indexOf(0, 0)) {
            case Some(_) => @Expect(false)
            case None => ()
        }
    }

    @TestCase
    func bufferIndexOutOfBoundsCase1(): Unit {
        let buffer = Buffer(Rect(2, 3, 4, 5))
        match (buffer.indexOf(1, 1)) {
            case Some(_) => @Expect(false)
            case None => ()
        }
    }

    @TestCase
    func bufferIndexOutOfBoundsCase2(): Unit {
        let buffer = Buffer(Rect(2, 3, 4, 5))
        match (buffer.indexOf(0, 2)) {
            case Some(_) => @Expect(false)
            case None => ()
        }
    }

    @TestCase
    func bufferIndexOutOfBoundsCase3(): Unit {
        let buffer = Buffer(Rect(2, 3, 4, 5))
        match (buffer.indexOf(1, 0)) {
            case Some(_) => @Expect(false)
            case None => ()
        }
    }

    @TestCase
    func bufferIndexOutOfBoundsCase4(): Unit {
        let buffer = Buffer(Rect(2, 3, 4, 5))
        match (buffer.indexOf(0, 1)) {
            case Some(_) => @Expect(false)
            case None => ()
        }
    }

    @TestCase
    func bufferIndexOutOfBoundsCase5(): Unit {
        let buffer = Buffer(Rect(2, 3, 4, 5))
        match (buffer.indexOf(1, 2)) {
            case Some(_) => @Expect(false)
            case None => ()
        }
    }

    @TestCase
    func bufferIndexOutOfBoundsCase6(): Unit {
        let buffer = Buffer(Rect(2, 3, 4, 5))
        match (buffer.indexOf(0, 0)) {
            case Some(_) => @Expect(false)
            case None => ()
        }
    }

    @TestCase
    func bufferIndexOutOfBoundsCase7(): Unit {
        let buffer = Buffer(Rect(2, 3, 4, 5))
        match (buffer.indexOf(1, 1)) {
            case Some(_) => @Expect(false)
            case None => ()
        }
    }

    @TestCase
    func bufferIndexOutOfBoundsCase8(): Unit {
        let buffer = Buffer(Rect(2, 3, 4, 5))
        match (buffer.indexOf(0, 2)) {
            case Some(_) => @Expect(false)
            case None => ()
        }
    }

    @TestCase
    func bufferIndexOutOfBoundsCase9(): Unit {
        let buffer = Buffer(Rect(2, 3, 4, 5))
        match (buffer.indexOf(1, 0)) {
            case Some(_) => @Expect(false)
            case None => ()
        }
    }

    @TestCase
    func bufferDiffCase0(): Unit {
        let before = Buffer(Rect(0, 0, 5, 1))
        let after = Buffer(Rect(0, 0, 5, 1))
        after.setString(0, 0, "x")
        @Expect(after.diff(before).size, 1)
    }

    @TestCase
    func bufferDiffCase1(): Unit {
        let before = Buffer(Rect(0, 0, 5, 1))
        let after = Buffer(Rect(0, 0, 5, 1))
        after.setString(1, 0, "x")
        @Expect(after.diff(before).size, 1)
    }

    @TestCase
    func bufferDiffCase2(): Unit {
        let before = Buffer(Rect(0, 0, 5, 1))
        let after = Buffer(Rect(0, 0, 5, 1))
        after.setString(2, 0, "x")
        @Expect(after.diff(before).size, 1)
    }

    @TestCase
    func bufferDiffCase3(): Unit {
        let before = Buffer(Rect(0, 0, 5, 1))
        let after = Buffer(Rect(0, 0, 5, 1))
        after.setString(3, 0, "x")
        @Expect(after.diff(before).size, 1)
    }

    @TestCase
    func bufferDiffCase4(): Unit {
        let before = Buffer(Rect(0, 0, 5, 1))
        let after = Buffer(Rect(0, 0, 5, 1))
        after.setString(4, 0, "x")
        @Expect(after.diff(before).size, 1)
    }

    @TestCase
    func stylePatchFgCase0(): Unit {
        let base = Style(fg: Color.Red, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Green))
        @Expect(patched, Style(fg: Color.Green, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase1(): Unit {
        let base = Style(fg: Color.Green, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Yellow))
        @Expect(patched, Style(fg: Color.Yellow, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase2(): Unit {
        let base = Style(fg: Color.Yellow, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Blue))
        @Expect(patched, Style(fg: Color.Blue, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase3(): Unit {
        let base = Style(fg: Color.Blue, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Magenta))
        @Expect(patched, Style(fg: Color.Magenta, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase4(): Unit {
        let base = Style(fg: Color.Magenta, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Cyan))
        @Expect(patched, Style(fg: Color.Cyan, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase5(): Unit {
        let base = Style(fg: Color.Cyan, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.White))
        @Expect(patched, Style(fg: Color.White, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase6(): Unit {
        let base = Style(fg: Color.White, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Red))
        @Expect(patched, Style(fg: Color.Red, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase7(): Unit {
        let base = Style(fg: Color.Red, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Green))
        @Expect(patched, Style(fg: Color.Green, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase8(): Unit {
        let base = Style(fg: Color.Green, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Yellow))
        @Expect(patched, Style(fg: Color.Yellow, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase9(): Unit {
        let base = Style(fg: Color.Yellow, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Blue))
        @Expect(patched, Style(fg: Color.Blue, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase10(): Unit {
        let base = Style(fg: Color.Blue, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Magenta))
        @Expect(patched, Style(fg: Color.Magenta, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase11(): Unit {
        let base = Style(fg: Color.Magenta, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Cyan))
        @Expect(patched, Style(fg: Color.Cyan, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase12(): Unit {
        let base = Style(fg: Color.Cyan, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.White))
        @Expect(patched, Style(fg: Color.White, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase13(): Unit {
        let base = Style(fg: Color.White, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Red))
        @Expect(patched, Style(fg: Color.Red, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase14(): Unit {
        let base = Style(fg: Color.Red, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Green))
        @Expect(patched, Style(fg: Color.Green, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase15(): Unit {
        let base = Style(fg: Color.Green, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Yellow))
        @Expect(patched, Style(fg: Color.Yellow, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase16(): Unit {
        let base = Style(fg: Color.Yellow, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Blue))
        @Expect(patched, Style(fg: Color.Blue, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase17(): Unit {
        let base = Style(fg: Color.Blue, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Magenta))
        @Expect(patched, Style(fg: Color.Magenta, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase18(): Unit {
        let base = Style(fg: Color.Magenta, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.Cyan))
        @Expect(patched, Style(fg: Color.Cyan, bg: Color.Black))
    }

    @TestCase
    func stylePatchFgCase19(): Unit {
        let base = Style(fg: Color.Cyan, bg: Color.Black)
        let patched = base.patch(Style(fg: Color.White))
        @Expect(patched, Style(fg: Color.White, bg: Color.Black))
    }

    @TestCase
    func styleWithBgCase0(): Unit {
        @Expect(Style().withBg(Color.Red), Style(bg: Color.Red))
    }

    @TestCase
    func styleWithBgCase1(): Unit {
        @Expect(Style().withBg(Color.Green), Style(bg: Color.Green))
    }

    @TestCase
    func styleWithBgCase2(): Unit {
        @Expect(Style().withBg(Color.Yellow), Style(bg: Color.Yellow))
    }

    @TestCase
    func styleWithBgCase3(): Unit {
        @Expect(Style().withBg(Color.Blue), Style(bg: Color.Blue))
    }

    @TestCase
    func styleWithBgCase4(): Unit {
        @Expect(Style().withBg(Color.Magenta), Style(bg: Color.Magenta))
    }

    @TestCase
    func styleWithBgCase5(): Unit {
        @Expect(Style().withBg(Color.Cyan), Style(bg: Color.Cyan))
    }

    @TestCase
    func styleWithBgCase6(): Unit {
        @Expect(Style().withBg(Color.White), Style(bg: Color.White))
    }

    @TestCase
    func styleWithBgCase7(): Unit {
        @Expect(Style().withBg(Color.Red), Style(bg: Color.Red))
    }

    @TestCase
    func styleWithBgCase8(): Unit {
        @Expect(Style().withBg(Color.Green), Style(bg: Color.Green))
    }

    @TestCase
    func styleWithBgCase9(): Unit {
        @Expect(Style().withBg(Color.Yellow), Style(bg: Color.Yellow))
    }

    @TestCase
    func modifierStrongCase0(): Unit {
        @Expect(Style().withModifier(Modifier.strong()).modifier.bold)
    }

    @TestCase
    func modifierStrongCase1(): Unit {
        @Expect(Style().withModifier(Modifier.strong()).modifier.bold)
    }

    @TestCase
    func modifierStrongCase2(): Unit {
        @Expect(Style().withModifier(Modifier.strong()).modifier.bold)
    }

    @TestCase
    func modifierStrongCase3(): Unit {
        @Expect(Style().withModifier(Modifier.strong()).modifier.bold)
    }

    @TestCase
    func modifierStrongCase4(): Unit {
        @Expect(Style().withModifier(Modifier.strong()).modifier.bold)
    }

    @TestCase
    func eventParserCharA(): Unit {
        let events = EventParser().push(unsafe { "a".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'a') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharB(): Unit {
        let events = EventParser().push(unsafe { "b".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'b') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharC(): Unit {
        let events = EventParser().push(unsafe { "c".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'c') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharD(): Unit {
        let events = EventParser().push(unsafe { "d".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'd') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharE(): Unit {
        let events = EventParser().push(unsafe { "e".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'e') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharF(): Unit {
        let events = EventParser().push(unsafe { "f".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'f') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharG(): Unit {
        let events = EventParser().push(unsafe { "g".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'g') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharH(): Unit {
        let events = EventParser().push(unsafe { "h".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'h') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharI(): Unit {
        let events = EventParser().push(unsafe { "i".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'i') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharJ(): Unit {
        let events = EventParser().push(unsafe { "j".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'j') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharK(): Unit {
        let events = EventParser().push(unsafe { "k".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'k') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharL(): Unit {
        let events = EventParser().push(unsafe { "l".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'l') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharM(): Unit {
        let events = EventParser().push(unsafe { "m".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'm') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharN(): Unit {
        let events = EventParser().push(unsafe { "n".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'n') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharO(): Unit {
        let events = EventParser().push(unsafe { "o".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'o') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharP(): Unit {
        let events = EventParser().push(unsafe { "p".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'p') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharQ(): Unit {
        let events = EventParser().push(unsafe { "q".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'q') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharR(): Unit {
        let events = EventParser().push(unsafe { "r".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'r') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharS(): Unit {
        let events = EventParser().push(unsafe { "s".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r's') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharT(): Unit {
        let events = EventParser().push(unsafe { "t".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r't') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharU(): Unit {
        let events = EventParser().push(unsafe { "u".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'u') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharV(): Unit {
        let events = EventParser().push(unsafe { "v".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'v') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharW(): Unit {
        let events = EventParser().push(unsafe { "w".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'w') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharX(): Unit {
        let events = EventParser().push(unsafe { "x".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'x') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharY(): Unit {
        let events = EventParser().push(unsafe { "y".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'y') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCharZ(): Unit {
        let events = EventParser().push(unsafe { "z".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'z') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserEnterKey(): Unit {
        let events = EventParser().push(unsafe { "\n".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(key) => match (key.code) {
                case KeyCode.Enter => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserBackspaceKey(): Unit {
        let events = EventParser().push(unsafe { "\u{7F}".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(key) => match (key.code) {
                case KeyCode.Backspace => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserTabKey(): Unit {
        let events = EventParser().push(unsafe { "\t".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(key) => match (key.code) {
                case KeyCode.Tab => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserCtrlCKey(): Unit {
        let events = EventParser().push(unsafe { "\u{03}".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(key) => match (key.code) {
                case KeyCode.CtrlC => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func textBufferInsertCase0(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 0), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase1(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 1), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase2(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 2), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase3(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 0), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase4(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 1), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase5(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 2), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase6(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 0), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase7(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 1), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase8(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 2), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase9(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 0), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase10(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 1), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase11(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 2), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase12(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 0), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase13(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 1), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase14(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 2), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase15(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 0), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase16(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 1), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase17(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 2), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase18(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 0), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferInsertCase19(): Unit {
        let buffer = TextBuffer(text: "ab")
        let pos = buffer.insert(TextPosition(0, 1), "X")
        @Expect(buffer.text().contains("X"))
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferFindCase0(): Unit {
        let buffer = TextBuffer(text: "alpha beta alpha")
        match (buffer.find("beta", start: TextPosition(0, 0))) {
            case Some(pos) => @Expect(pos.column, 6)
            case None => @Expect(false)
        }
    }

    @TestCase
    func textBufferFindCase1(): Unit {
        let buffer = TextBuffer(text: "alpha beta alpha")
        match (buffer.find("beta", start: TextPosition(0, 1))) {
            case Some(pos) => @Expect(pos.column, 6)
            case None => @Expect(false)
        }
    }

    @TestCase
    func textBufferFindCase2(): Unit {
        let buffer = TextBuffer(text: "alpha beta alpha")
        match (buffer.find("beta", start: TextPosition(0, 2))) {
            case Some(pos) => @Expect(pos.column, 6)
            case None => @Expect(false)
        }
    }

    @TestCase
    func textBufferFindCase3(): Unit {
        let buffer = TextBuffer(text: "alpha beta alpha")
        match (buffer.find("beta", start: TextPosition(0, 3))) {
            case Some(pos) => @Expect(pos.column, 6)
            case None => @Expect(false)
        }
    }

    @TestCase
    func textBufferFindCase4(): Unit {
        let buffer = TextBuffer(text: "alpha beta alpha")
        match (buffer.find("beta", start: TextPosition(0, 4))) {
            case Some(pos) => @Expect(pos.column, 6)
            case None => @Expect(false)
        }
    }

    @TestCase
    func textBufferFindCase5(): Unit {
        let buffer = TextBuffer(text: "alpha beta alpha")
        match (buffer.find("beta", start: TextPosition(0, 5))) {
            case Some(pos) => @Expect(pos.column, 6)
            case None => @Expect(false)
        }
    }

    @TestCase
    func textBufferFindCase6(): Unit {
        let buffer = TextBuffer(text: "alpha beta alpha")
        match (buffer.find("beta", start: TextPosition(0, 0))) {
            case Some(pos) => @Expect(pos.column, 6)
            case None => @Expect(false)
        }
    }

    @TestCase
    func textBufferFindCase7(): Unit {
        let buffer = TextBuffer(text: "alpha beta alpha")
        match (buffer.find("beta", start: TextPosition(0, 1))) {
            case Some(pos) => @Expect(pos.column, 6)
            case None => @Expect(false)
        }
    }

    @TestCase
    func textBufferFindCase8(): Unit {
        let buffer = TextBuffer(text: "alpha beta alpha")
        match (buffer.find("beta", start: TextPosition(0, 2))) {
            case Some(pos) => @Expect(pos.column, 6)
            case None => @Expect(false)
        }
    }

    @TestCase
    func textBufferFindCase9(): Unit {
        let buffer = TextBuffer(text: "alpha beta alpha")
        match (buffer.find("beta", start: TextPosition(0, 3))) {
            case Some(pos) => @Expect(pos.column, 6)
            case None => @Expect(false)
        }
    }

    @TestCase
    func textBufferFindCase10(): Unit {
        let buffer = TextBuffer(text: "alpha beta alpha")
        match (buffer.find("beta", start: TextPosition(0, 4))) {
            case Some(pos) => @Expect(pos.column, 6)
            case None => @Expect(false)
        }
    }

    @TestCase
    func textBufferFindCase11(): Unit {
        let buffer = TextBuffer(text: "alpha beta alpha")
        match (buffer.find("beta", start: TextPosition(0, 5))) {
            case Some(pos) => @Expect(pos.column, 6)
            case None => @Expect(false)
        }
    }

    @TestCase
    func textBufferFindCase12(): Unit {
        let buffer = TextBuffer(text: "alpha beta alpha")
        match (buffer.find("beta", start: TextPosition(0, 0))) {
            case Some(pos) => @Expect(pos.column, 6)
            case None => @Expect(false)
        }
    }

    @TestCase
    func textBufferFindCase13(): Unit {
        let buffer = TextBuffer(text: "alpha beta alpha")
        match (buffer.find("beta", start: TextPosition(0, 1))) {
            case Some(pos) => @Expect(pos.column, 6)
            case None => @Expect(false)
        }
    }

    @TestCase
    func textBufferFindCase14(): Unit {
        let buffer = TextBuffer(text: "alpha beta alpha")
        match (buffer.find("beta", start: TextPosition(0, 2))) {
            case Some(pos) => @Expect(pos.column, 6)
            case None => @Expect(false)
        }
    }

    @TestCase
    func textBufferReplaceAllCase0(): Unit {
        let buffer = TextBuffer(text: "one two one")
        @Expect(buffer.replaceAll("one", "0"), 2)
        @Expect(buffer.text(), "0 two 0")
    }

    @TestCase
    func textBufferReplaceAllCase1(): Unit {
        let buffer = TextBuffer(text: "one two one")
        @Expect(buffer.replaceAll("one", "1"), 2)
        @Expect(buffer.text(), "1 two 1")
    }

    @TestCase
    func textBufferReplaceAllCase2(): Unit {
        let buffer = TextBuffer(text: "one two one")
        @Expect(buffer.replaceAll("one", "2"), 2)
        @Expect(buffer.text(), "2 two 2")
    }

    @TestCase
    func textBufferReplaceAllCase3(): Unit {
        let buffer = TextBuffer(text: "one two one")
        @Expect(buffer.replaceAll("one", "3"), 2)
        @Expect(buffer.text(), "3 two 3")
    }

    @TestCase
    func textBufferReplaceAllCase4(): Unit {
        let buffer = TextBuffer(text: "one two one")
        @Expect(buffer.replaceAll("one", "4"), 2)
        @Expect(buffer.text(), "4 two 4")
    }

    @TestCase
    func textBufferReplaceAllCase5(): Unit {
        let buffer = TextBuffer(text: "one two one")
        @Expect(buffer.replaceAll("one", "5"), 2)
        @Expect(buffer.text(), "5 two 5")
    }

    @TestCase
    func textBufferReplaceAllCase6(): Unit {
        let buffer = TextBuffer(text: "one two one")
        @Expect(buffer.replaceAll("one", "6"), 2)
        @Expect(buffer.text(), "6 two 6")
    }

    @TestCase
    func textBufferReplaceAllCase7(): Unit {
        let buffer = TextBuffer(text: "one two one")
        @Expect(buffer.replaceAll("one", "7"), 2)
        @Expect(buffer.text(), "7 two 7")
    }

    @TestCase
    func textBufferReplaceAllCase8(): Unit {
        let buffer = TextBuffer(text: "one two one")
        @Expect(buffer.replaceAll("one", "8"), 2)
        @Expect(buffer.text(), "8 two 8")
    }

    @TestCase
    func textBufferReplaceAllCase9(): Unit {
        let buffer = TextBuffer(text: "one two one")
        @Expect(buffer.replaceAll("one", "9"), 2)
        @Expect(buffer.text(), "9 two 9")
    }

    @TestCase
    func textBufferDeleteBackwardCase0(): Unit {
        let buffer = TextBuffer(text: "abc")
        let pos = buffer.deleteBackward(TextPosition(0, 0))
        @Expect(buffer.lineCount(), 1)
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferDeleteBackwardCase1(): Unit {
        let buffer = TextBuffer(text: "abc")
        let pos = buffer.deleteBackward(TextPosition(0, 1))
        @Expect(buffer.lineCount(), 1)
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferDeleteBackwardCase2(): Unit {
        let buffer = TextBuffer(text: "abc")
        let pos = buffer.deleteBackward(TextPosition(0, 2))
        @Expect(buffer.lineCount(), 1)
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferDeleteBackwardCase3(): Unit {
        let buffer = TextBuffer(text: "abc")
        let pos = buffer.deleteBackward(TextPosition(0, 3))
        @Expect(buffer.lineCount(), 1)
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferDeleteBackwardCase4(): Unit {
        let buffer = TextBuffer(text: "abc")
        let pos = buffer.deleteBackward(TextPosition(0, 0))
        @Expect(buffer.lineCount(), 1)
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferDeleteBackwardCase5(): Unit {
        let buffer = TextBuffer(text: "abc")
        let pos = buffer.deleteBackward(TextPosition(0, 1))
        @Expect(buffer.lineCount(), 1)
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferDeleteBackwardCase6(): Unit {
        let buffer = TextBuffer(text: "abc")
        let pos = buffer.deleteBackward(TextPosition(0, 2))
        @Expect(buffer.lineCount(), 1)
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferDeleteBackwardCase7(): Unit {
        let buffer = TextBuffer(text: "abc")
        let pos = buffer.deleteBackward(TextPosition(0, 3))
        @Expect(buffer.lineCount(), 1)
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferDeleteBackwardCase8(): Unit {
        let buffer = TextBuffer(text: "abc")
        let pos = buffer.deleteBackward(TextPosition(0, 0))
        @Expect(buffer.lineCount(), 1)
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferDeleteBackwardCase9(): Unit {
        let buffer = TextBuffer(text: "abc")
        let pos = buffer.deleteBackward(TextPosition(0, 1))
        @Expect(buffer.lineCount(), 1)
        @Expect(pos.line, 0)
    }

    @TestCase
    func textBufferUndoRedoCase0(): Unit {
        let buffer = TextBuffer(text: "a")
        _ = buffer.insert(TextPosition(0, 1), "0")
        @Expect(buffer.undo())
        @Expect(buffer.text(), "a")
        @Expect(buffer.redo())
        @Expect(buffer.text(), "a0")
    }

    @TestCase
    func textBufferUndoRedoCase1(): Unit {
        let buffer = TextBuffer(text: "a")
        _ = buffer.insert(TextPosition(0, 1), "1")
        @Expect(buffer.undo())
        @Expect(buffer.text(), "a")
        @Expect(buffer.redo())
        @Expect(buffer.text(), "a1")
    }

    @TestCase
    func textBufferUndoRedoCase2(): Unit {
        let buffer = TextBuffer(text: "a")
        _ = buffer.insert(TextPosition(0, 1), "2")
        @Expect(buffer.undo())
        @Expect(buffer.text(), "a")
        @Expect(buffer.redo())
        @Expect(buffer.text(), "a2")
    }

    @TestCase
    func textBufferUndoRedoCase3(): Unit {
        let buffer = TextBuffer(text: "a")
        _ = buffer.insert(TextPosition(0, 1), "3")
        @Expect(buffer.undo())
        @Expect(buffer.text(), "a")
        @Expect(buffer.redo())
        @Expect(buffer.text(), "a3")
    }

    @TestCase
    func textBufferUndoRedoCase4(): Unit {
        let buffer = TextBuffer(text: "a")
        _ = buffer.insert(TextPosition(0, 1), "4")
        @Expect(buffer.undo())
        @Expect(buffer.text(), "a")
        @Expect(buffer.redo())
        @Expect(buffer.text(), "a4")
    }

    @TestCase
    func paragraphLeftRenderCase0(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case0").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase1(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case1").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase2(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case2").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase3(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case3").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase4(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case4").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase5(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case5").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase6(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case6").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase7(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case7").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase8(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case8").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase9(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case9").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase10(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case10").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase11(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case11").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase12(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case12").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase13(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case13").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase14(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case14").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase15(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case15").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase16(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case16").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase17(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case17").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase18(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case18").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphLeftRenderCase19(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("case19").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }

    @TestCase
    func paragraphCenterRenderCase0(): Unit {
        let buffer = Buffer(Rect(0, 0, 6, 1))
        Paragraph("ok", align: TextAlign.Center).render(buffer.area, buffer)
        @Expect(buffer.getCell(2, 0).symbol, "o")
    }

    @TestCase
    func paragraphCenterRenderCase1(): Unit {
        let buffer = Buffer(Rect(0, 0, 7, 1))
        Paragraph("ok", align: TextAlign.Center).render(buffer.area, buffer)
        @Expect(buffer.getCell(2, 0).symbol, "o")
    }

    @TestCase
    func paragraphCenterRenderCase2(): Unit {
        let buffer = Buffer(Rect(0, 0, 8, 1))
        Paragraph("ok", align: TextAlign.Center).render(buffer.area, buffer)
        @Expect(buffer.getCell(3, 0).symbol, "o")
    }

    @TestCase
    func paragraphCenterRenderCase3(): Unit {
        let buffer = Buffer(Rect(0, 0, 9, 1))
        Paragraph("ok", align: TextAlign.Center).render(buffer.area, buffer)
        @Expect(buffer.getCell(3, 0).symbol, "o")
    }

    @TestCase
    func paragraphCenterRenderCase4(): Unit {
        let buffer = Buffer(Rect(0, 0, 10, 1))
        Paragraph("ok", align: TextAlign.Center).render(buffer.area, buffer)
        @Expect(buffer.getCell(4, 0).symbol, "o")
    }

    @TestCase
    func paragraphCenterRenderCase5(): Unit {
        let buffer = Buffer(Rect(0, 0, 11, 1))
        Paragraph("ok", align: TextAlign.Center).render(buffer.area, buffer)
        @Expect(buffer.getCell(4, 0).symbol, "o")
    }

    @TestCase
    func paragraphCenterRenderCase6(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 1))
        Paragraph("ok", align: TextAlign.Center).render(buffer.area, buffer)
        @Expect(buffer.getCell(5, 0).symbol, "o")
    }

    @TestCase
    func paragraphCenterRenderCase7(): Unit {
        let buffer = Buffer(Rect(0, 0, 13, 1))
        Paragraph("ok", align: TextAlign.Center).render(buffer.area, buffer)
        @Expect(buffer.getCell(5, 0).symbol, "o")
    }

    @TestCase
    func paragraphCenterRenderCase8(): Unit {
        let buffer = Buffer(Rect(0, 0, 14, 1))
        Paragraph("ok", align: TextAlign.Center).render(buffer.area, buffer)
        @Expect(buffer.getCell(6, 0).symbol, "o")
    }

    @TestCase
    func paragraphCenterRenderCase9(): Unit {
        let buffer = Buffer(Rect(0, 0, 15, 1))
        Paragraph("ok", align: TextAlign.Center).render(buffer.area, buffer)
        @Expect(buffer.getCell(6, 0).symbol, "o")
    }

    @TestCase
    func inputHandleCharCase0(): Unit {
        let input = Input()
        @Expect(input.handle(KeyEvent(KeyCode.Char(r'a'))))
        @Expect(input.value, "a")
        @Expect(input.cursor, 1)
    }

    @TestCase
    func inputHandleCharCase1(): Unit {
        let input = Input()
        @Expect(input.handle(KeyEvent(KeyCode.Char(r'b'))))
        @Expect(input.value, "b")
        @Expect(input.cursor, 1)
    }

    @TestCase
    func inputHandleCharCase2(): Unit {
        let input = Input()
        @Expect(input.handle(KeyEvent(KeyCode.Char(r'c'))))
        @Expect(input.value, "c")
        @Expect(input.cursor, 1)
    }

    @TestCase
    func inputHandleCharCase3(): Unit {
        let input = Input()
        @Expect(input.handle(KeyEvent(KeyCode.Char(r'd'))))
        @Expect(input.value, "d")
        @Expect(input.cursor, 1)
    }

    @TestCase
    func inputHandleCharCase4(): Unit {
        let input = Input()
        @Expect(input.handle(KeyEvent(KeyCode.Char(r'e'))))
        @Expect(input.value, "e")
        @Expect(input.cursor, 1)
    }

    @TestCase
    func inputHandleCharCase5(): Unit {
        let input = Input()
        @Expect(input.handle(KeyEvent(KeyCode.Char(r'f'))))
        @Expect(input.value, "f")
        @Expect(input.cursor, 1)
    }

    @TestCase
    func inputHandleCharCase6(): Unit {
        let input = Input()
        @Expect(input.handle(KeyEvent(KeyCode.Char(r'g'))))
        @Expect(input.value, "g")
        @Expect(input.cursor, 1)
    }

    @TestCase
    func inputHandleCharCase7(): Unit {
        let input = Input()
        @Expect(input.handle(KeyEvent(KeyCode.Char(r'h'))))
        @Expect(input.value, "h")
        @Expect(input.cursor, 1)
    }

    @TestCase
    func inputHandleCharCase8(): Unit {
        let input = Input()
        @Expect(input.handle(KeyEvent(KeyCode.Char(r'i'))))
        @Expect(input.value, "i")
        @Expect(input.cursor, 1)
    }

    @TestCase
    func inputHandleCharCase9(): Unit {
        let input = Input()
        @Expect(input.handle(KeyEvent(KeyCode.Char(r'j'))))
        @Expect(input.value, "j")
        @Expect(input.cursor, 1)
    }

    @TestCase
    func listSelectedRenderCase0(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 3))
        List(["zero", "one", "two"], selected: Some(0)).render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, ">")
    }

    @TestCase
    func listSelectedRenderCase1(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 3))
        List(["zero", "one", "two"], selected: Some(1)).render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 1).symbol, ">")
    }

    @TestCase
    func listSelectedRenderCase2(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 3))
        List(["zero", "one", "two"], selected: Some(2)).render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 2).symbol, ">")
    }

    @TestCase
    func listSelectedRenderCase3(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 3))
        List(["zero", "one", "two"], selected: Some(0)).render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, ">")
    }

    @TestCase
    func listSelectedRenderCase4(): Unit {
        let buffer = Buffer(Rect(0, 0, 12, 3))
        List(["zero", "one", "two"], selected: Some(1)).render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 1).symbol, ">")
    }

}
