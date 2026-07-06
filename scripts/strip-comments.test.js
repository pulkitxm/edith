import { expect, test } from "bun:test";
import {
  build,
  cssComments,
  htmlComments,
  jsoncComments,
  swiftComments,
} from "./strip-comments.mjs";

const strip = (fn, src) => build(src, fn(src).remove);

test("swift: strips a trailing line comment, keeps the code", () => {
  const src = 'let u = "https://x.com" // a comment';
  expect(swiftComments(src).remove.length).toBe(1);
  expect(strip(swiftComments, src).trimEnd()).toBe('let u = "https://x.com"');
});

test("swift: // and /* */ inside strings are not comments", () => {
  expect(swiftComments('let r = #"a // b /* c */"#').remove.length).toBe(0);
  expect(swiftComments('let s = "\\(a)//x"').remove.length).toBe(0);
  expect(
    swiftComments('let m = """\n// not a comment\n"""').remove.length,
  ).toBe(0);
  expect(swiftComments('let m = #"""\n// nope\n"""#').remove.length).toBe(0);
});

test("swift: division is not a comment", () => {
  expect(swiftComments("let a = 1 / 2 // c").remove.length).toBe(1);
});

test("swift: nested block comments are one range", () => {
  const src = "/* a /* b */ c */ let x = 1";
  expect(swiftComments(src).remove.length).toBe(1);
  expect(strip(swiftComments, src).trim()).toBe("let x = 1");
});

test("swift: doc comments and MARK are stripped", () => {
  expect(swiftComments("/// doc\nfunc f() {}").remove.length).toBe(1);
  expect(swiftComments("// MARK: - Section\nlet x = 1").remove.length).toBe(1);
});

test("swift: functional directives are kept", () => {
  expect(swiftComments("// swift-tools-version:6.0\nimport X").kept).toBe(1);
  expect(swiftComments("// swiftlint:disable foo\nlet x = 1").kept).toBe(1);
  expect(swiftComments("// swift-format-ignore\nlet x = 1").kept).toBe(1);
});

test("html: strips <!-- --> comments", () => {
  expect(htmlComments("<div><!-- hi --></div>").remove.length).toBe(1);
  expect(strip(htmlComments, "<div><!-- hi --></div>")).toBe("<div></div>");
});

test("css: strips /* */ but keeps /*! */", () => {
  expect(cssComments("a{color:red}/* x */").remove.length).toBe(1);
  expect(cssComments("/*! keep */a{}").kept).toBe(1);
});

test("css: slashes inside strings are safe", () => {
  expect(cssComments('a{content:"/* not a comment */"}').remove.length).toBe(0);
});

test("json: strips // and /* */ comments", () => {
  expect(jsoncComments('{\n// c\n"a": 1\n}').remove.length).toBe(1);
  expect(jsoncComments('{"url": "http://x"}').remove.length).toBe(0);
});
