export const definition = {
  "schema": 1,
  "owner": "calendar",
  "activation": {
    "kind": "native-accessibility",
    "control": "Details",
    "operation": "calendar.ui.action",
    "sources": [
      {
        "path": "Extensions/calendar/UI/CalendarAgendaView.swift",
        "sha256": "5ecd3fe2df54a3c0ca6734054ab24cf181a3806e1d2e2f76b08038b5fba77bd9"
      },
      {
        "path": "Extensions/calendar/ViewModels/CalendarUIFacade.swift",
        "sha256": "b01787385b1a1324195d0542ff3bebc71de20ee04c91d83d2d82bb1dfbd87f8e"
      },
      {
        "path": "Extensions/calendar/Runtime.swift",
        "sha256": "923eccb6e2cba5aed3ec5b9c74dde78befce60b1cb9e7a4baec0271bbe846e78"
      }
    ]
  },
  "operations": [
    "calendar.ui.action",
    "calendar.ui.list"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "blocked original Details expansion and retained agenda notes"
  },
  "persistence": {
    "applicable": true,
    "name": "retained synthetic agenda notes"
  },
  "limits": [
    "synthetic-platform-adapter",
    "private-filesystem"
  ]
};
