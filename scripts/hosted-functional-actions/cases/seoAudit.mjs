export const definition = {
  "schema": 1,
  "owner": "seoAudit",
  "activation": {
    "kind": "original-control-callback",
    "control": "Rename project",
    "operation": "seoAudit.ui.action",
    "sources": [
      {
        "path": "Extensions/seoAudit/ViewModels/SEOAuditModel.swift",
        "sha256": "ebc591d8248421a15d3144789ee4dea621b76310c2c7bf01899ff51ae2c3f0f2"
      },
      {
        "path": "Extensions/seoAudit/Views/SEOAuditPage.swift",
        "sha256": "8f21320bf901edff73a04f3494f1658fa49a5d8053c7028b93e4e4e65a51b7dc"
      }
    ],
    "mutation": {
      "kind": "state-transition",
      "payloadKeys": [
        "action",
        "id",
        "name"
      ]
    }
  },
  "operations": [
    "seoAudit.ui.action"
  ],
  "observation": {
    "kind": "owned-file-output",
    "name": "renamed synthetic SEO project"
  },
  "persistence": {
    "applicable": true,
    "name": "SEO project name"
  },
  "limits": [
    "private-filesystem"
  ]
};
