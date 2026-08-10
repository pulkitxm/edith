import { expect, test } from "bun:test";
import { desktopPlatform } from "../apps/site/platform.js";

test("detects macOS desktops", () => {
  expect(desktopPlatform("MacIntel", "Mozilla/5.0 Macintosh", 0)).toBe("macos");
});

test("does not offer a Mac download to iPad desktop mode", () => {
  expect(desktopPlatform("MacIntel", "Mozilla/5.0 Macintosh", 5)).toBeNull();
});

test("detects Linux desktops", () => {
  expect(desktopPlatform("Linux x86_64", "Mozilla/5.0 X11 Linux", 0)).toBe(
    "linux",
  );
});

test("does not offer an Ubuntu package to Android or ChromeOS", () => {
  expect(desktopPlatform("Linux armv8l", "Mozilla/5.0 Android", 5)).toBeNull();
  expect(desktopPlatform("Linux x86_64", "Mozilla/5.0 CrOS", 0)).toBeNull();
});

test("leaves unsupported desktop systems unselected", () => {
  expect(desktopPlatform("Win32", "Mozilla/5.0 Windows", 0)).toBeNull();
});
