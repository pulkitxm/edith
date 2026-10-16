export function rewriteArgumentParserWarnings(source, path) {
  const replacements = {
    "Parsable Types/ParsableArguments.swift": [
      '  public static var _errorPrefix: String {\n    "\\(_errorLabel): "\n  }',
      '  public static var _errorPrefix: String {\n    "Error: "\n  }',
    ],
    "Usage/DumpHelpGenerator.swift": [
      "    case .customDeprecated(_):\n      self = .customDeprecated",
      "    case .customDeprecated(_):\n      self = .custom",
    ],
  };
  const replacement = replacements[path];
  if (replacement) {
    const [previous, current] = replacement;
    if (source.split(previous).length !== 2)
      throw new Error(`Unexpected pinned ArgumentParser source ${path}`);
    source = source.replace(previous, current);
  }
  return source;
}
