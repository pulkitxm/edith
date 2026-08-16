export function desktopPlatform(platform, agent, maxTouchPoints) {
  const isMobileApple = platform === "MacIntel" && maxTouchPoints > 1;
  if (/Mac/i.test(platform) && !isMobileApple) {
    return "macos";
  }
  if (/Linux|X11/i.test(platform) && !/Android|CrOS/i.test(agent)) {
    return "linux";
  }
  return null;
}

export function currentDesktopPlatform() {
  const agent = navigator.userAgent || "";
  const platform =
    navigator.userAgentData?.platform || navigator.platform || agent;
  return desktopPlatform(platform, agent, navigator.maxTouchPoints || 0);
}
