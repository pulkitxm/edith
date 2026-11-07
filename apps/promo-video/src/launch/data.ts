export type Category = 'Agents' | 'Desk' | 'Developer' | 'Media' | 'Utilities' | 'Labs';

export type ExtensionEntry = {
  id: string;
  title: string;
  category: Category;
  tagline: string;
};

export const extensions: ExtensionEntry[] = [
  {id: 'usage', title: 'Usage', category: 'Agents', tagline: 'What your coding agents cost'},
  {id: 'herdr', title: 'Agents', category: 'Agents', tagline: 'Every coding agent on one board'},
  {id: 'studio', title: 'Studio', category: 'Media', tagline: 'PDFs, images, video and audio'},
  {id: 'downloads', title: 'Downloads', category: 'Media', tagline: 'Save media from any link'},
  {id: 'attention', title: 'Attention', category: 'Developer', tagline: 'See where your day went'},
  {id: 'clipboard', title: 'Clipboard', category: 'Desk', tagline: 'Everything you copy, searchable'},
  {id: 'notchShelf', title: 'Notch Shelf', category: 'Desk', tagline: 'A tray that lives in the notch'},
  {id: 'machines', title: 'Machines', category: 'Agents', tagline: 'Servers and containers, one place'},
  {id: 'terminal', title: 'Terminal', category: 'Agents', tagline: 'A fast built-in terminal'},
  {id: 'music', title: 'Music', category: 'Media', tagline: 'Your music, always playing'},
  {id: 'virtualCamera', title: 'Virtual Camera', category: 'Media', tagline: 'Look your best on every call'},
  {id: 'database', title: 'Database', category: 'Developer', tagline: 'Browse and edit databases'},
  {id: 'codeStats', title: 'Code Stats', category: 'Developer', tagline: 'Streaks across every repo'},
  {id: 'latex', title: 'LaTeX', category: 'Developer', tagline: 'Live PDF next to your source'},
  {id: 'homebrew', title: 'Homebrew', category: 'Utilities', tagline: 'Packages without the terminal'},
  {id: 'appMaintenance', title: 'App Updates', category: 'Utilities', tagline: 'Keep every app current'},
  {id: 'cleaner', title: 'Cleaner', category: 'Utilities', tagline: 'Win back disk space safely'},
  {id: 'blitztree', title: 'Disk Map', category: 'Utilities', tagline: 'See what fills your disk'},
  {id: 'bifrost', title: 'Launcher', category: 'Desk', tagline: 'Apps, math and files in one bar'},
  {id: 'colorPicker', title: 'Color Picker', category: 'Desk', tagline: 'Any pixel, any format'},
  {id: 'emoji', title: 'Emoji Picker', category: 'Desk', tagline: 'Type any emoji, anywhere'},
  {id: 'audioMixer', title: 'Audio Mixer', category: 'Desk', tagline: 'Volume for every app'},
  {id: 'focusDim', title: 'Focus Dim', category: 'Desk', tagline: 'Dim everything else'},
  {id: 'keystrokeHighlight', title: 'Keystrokes', category: 'Desk', tagline: 'Show keys for demos'},
  {id: 'micMute', title: 'Mic Mute', category: 'Utilities', tagline: 'Every mic, one shortcut'},
  {id: 'keepAwake', title: 'Keep Awake', category: 'Utilities', tagline: 'No sleep while you work'},
  {id: 'lidAwake', title: 'Lid Awake', category: 'Utilities', tagline: 'Runs with the lid closed'},
  {id: 'calendar', title: 'Calendar', category: 'Utilities', tagline: 'Next meeting, one click'},
  {id: 'presenter', title: 'Presenter', category: 'Utilities', tagline: 'Blur private details'},
  {id: 'system', title: 'Running Apps', category: 'Utilities', tagline: 'Quit what you do not need'},
  {id: 'systemStats', title: 'Menu Bar Stats', category: 'Utilities', tagline: 'CPU and memory at a glance'},
  {id: 'timeLapse', title: 'Screen Recorder', category: 'Media', tagline: 'Record or time-lapse'},
  {id: 'socialManager', title: 'Social Manager', category: 'Media', tagline: 'Every account, side by side'},
  {id: 'companion', title: 'Memory', category: 'Agents', tagline: 'A private memory you can ask'},
  {id: 'plugins', title: 'Plugins', category: 'Agents', tagline: 'Skills for your coding agents'},
  {id: 'docs', title: 'Docs', category: 'Agents', tagline: 'Describe it, find the command'},
  {id: 'quinjet', title: 'Code Review', category: 'Agents', tagline: 'Review PRs in a focused space'},
  {id: 'seoAudit', title: 'Site Audit', category: 'Developer', tagline: 'SEO problems, page by page'},
  {id: 'jev', title: 'Jev', category: 'Labs', tagline: 'Smarter decisions'},
  {id: 'hinge', title: 'Hinge', category: 'Labs', tagline: 'Fold your desktop'},
  {id: 'windowSweaters', title: 'Window Sweaters', category: 'Labs', tagline: 'Knit a sweater on every window'},
];

export const facts = {
  extensions: extensions.length,
  studioTools: 108,
  pdfTools: 37,
  dmgBeforeMb: 36.9,
  dmgNowMb: 7.3,
  idleMemoryMb: 22,
  releases: 385,
};
