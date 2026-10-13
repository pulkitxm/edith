import Foundation

public enum ClaudeSubscriptionAuthentication {
    public static func posixStatus(_ status: String) -> String {
        "{ " + status
            + "; subscription_status_exit=$?; printf '\\nsubscription_exit:%s\\n' \"$subscription_status_exit\"; }"
            + " | { LC_ALL=C od -An -v -tu1; subscription_od_exit=$?; printf 'subscription_od_exit:%s\\n' \"$subscription_od_exit\"; }"
            + " | LC_ALL=C awk " + quote(parser)
    }

    public static func posix(status: String, login: String, launch: String, failure: String)
        -> String
    {
        "subscription_authenticated=0; if " + posixStatus(status)
            + "; then subscription_authenticated=1; else " + login + "; if " + posixStatus(status)
            + "; then subscription_authenticated=1; fi; fi; if [ \"$subscription_authenticated\" -eq 1 ]; then "
            + launch + "; else printf '%s\\n' " + quote(failure) + "; false; fi"
    }

    public static func powerShell(
        status: String, login: String, launch: String, failure: String
    ) -> String {
        let read =
            "$subscriptionLogin = $null; $LASTEXITCODE = $null; $subscriptionOutput = " + status
            + "; $subscriptionStatusExit = $LASTEXITCODE; try { if ($subscriptionStatusExit -eq 0) { "
            + "$subscriptionLogin = ($subscriptionOutput -join \"`n\") | ConvertFrom-Json -ErrorAction Stop } } catch { $subscriptionLogin = $null }"
        let authenticated =
            "$subscriptionStatusExit -eq 0 -and $subscriptionLogin -is [pscustomobject]"
            + " -and ($subscriptionLogin.PSObject.Properties.Name -ccontains 'loggedIn')"
            + " -and ($subscriptionLogin.PSObject.Properties.Name -ccontains 'authMethod')"
            + " -and $subscriptionLogin.loggedIn -is [bool] -and $subscriptionLogin.loggedIn -eq $true"
            + " -and $subscriptionLogin.authMethod -is [string] -and $subscriptionLogin.authMethod -ceq 'claude.ai'"
        return read + "; if (!(" + authenticated + ")) { " + login + "; " + read
            + " }; if (" + authenticated + ") { " + launch + " } else { Write-Error "
            + quotePowerShell(failure) + " }"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func quotePowerShell(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static let parser = #"""
        function fail() { invalid = 1; return 0 }
        function character(c) { return sprintf("%c", c) }
        function whitespace() {
            while (position <= count && (bytes[position] == 32 || bytes[position] == 9 || bytes[position] == 10 || bytes[position] == 13)) position++
        }
        function hex(c) {
            if (c >= 48 && c <= 57) return c - 48
            if (c >= 65 && c <= 70) return c - 55
            if (c >= 97 && c <= 102) return c - 87
            return -1
        }
        function codepoint(    i, c, value) {
            value = 0
            for (i = 0; i < 4; i++) {
                if (position > count || (c = hex(bytes[position++])) < 0) { fail(); return -1 }
                value = value * 16 + c
            }
            return value
        }
        function string(    c, v, low, continuations, first, i, continuationByte) {
            if (bytes[position++] != 34) return fail()
            text = ""
            while (position <= count) {
                c = bytes[position++]
                if (c == 34) { kind = 3; return 1 }
                if (c < 32) return fail()
                if (c == 92) {
                    if (position > count) return fail()
                    c = bytes[position++]
                    if (c == 34 || c == 92 || c == 47) text = text character(c)
                    else if (c == 98 || c == 102 || c == 110 || c == 114 || c == 116) text = text "~"
                    else if (c == 117) {
                        v = codepoint()
                        if (v < 0) return 0
                        if (v >= 55296 && v <= 56319) {
                            if (position + 5 > count || bytes[position++] != 92 || bytes[position++] != 117) return fail()
                            low = codepoint()
                            if (low < 56320 || low > 57343) return fail()
                            text = text "~"
                        } else if (v >= 56320 && v <= 57343) return fail()
                        else text = text ((v > 0 && v < 128) ? character(v) : "~")
                    } else return fail()
                } else if (c < 128) text = text character(c)
                else {
                    if (c >= 194 && c <= 223) continuations = 1
                    else if (c >= 224 && c <= 239) continuations = 2
                    else if (c >= 240 && c <= 244) continuations = 3
                    else return fail()
                    if (position + continuations - 1 > count) return fail()
                    first = bytes[position]
                    if ((c == 224 && first < 160) || (c == 237 && first > 159) || (c == 240 && first < 144) || (c == 244 && first > 143)) return fail()
                    for (i = 0; i < continuations; i++) {
                        continuationByte = bytes[position++]
                        if (continuationByte < 128 || continuationByte > 191) return fail()
                    }
                    text = text "~"
                }
            }
            return fail()
        }
        function literal(word, result,    i) {
            for (i = 1; i <= length(word); i++) {
                if (position > count || character(bytes[position++]) != substr(word, i, 1)) return fail()
            }
            kind = result
            return 1
        }
        function number(    token, c) {
            token = ""
            while (position <= count) {
                c = bytes[position]
                if (!((c >= 48 && c <= 57) || c == 45 || c == 43 || c == 46 || c == 69 || c == 101)) break
                token = token character(c)
                position++
            }
            if (token !~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) return fail()
            kind = 4
            return 1
        }
        function object(depth,    key) {
            position++
            whitespace()
            if (bytes[position] == 125) { position++; kind = 5; return 1 }
            while (position <= count) {
                if (!string()) return 0
                key = text
                whitespace()
                if (bytes[position++] != 58) return fail()
                if (!value(depth + 1)) return 0
                if (depth == 1 && key == "loggedIn") {
                    if (++seenLogged != 1 || kind != 1) return fail()
                }
                if (depth == 1 && key == "authMethod") {
                    if (++seenMethod != 1 || kind != 3 || text != "claude.ai") return fail()
                }
                whitespace()
                if (bytes[position] == 125) { position++; kind = 5; return 1 }
                if (bytes[position++] != 44) return fail()
                whitespace()
            }
            return fail()
        }
        function array(depth) {
            position++
            whitespace()
            if (bytes[position] == 93) { position++; kind = 6; return 1 }
            while (position <= count) {
                if (!value(depth + 1)) return 0
                whitespace()
                if (bytes[position] == 93) { position++; kind = 6; return 1 }
                if (bytes[position++] != 44) return fail()
            }
            return fail()
        }
        function value(depth,    c) {
            if (depth > 64) return fail()
            whitespace()
            c = bytes[position]
            if (c == 123) return object(depth)
            if (c == 91) return array(depth)
            if (c == 34) return string()
            if (c == 116) return literal("true", 1)
            if (c == 102) return literal("false", 2)
            if (c == 110) return literal("null", 7)
            return number()
        }
        /^subscription_od_exit:0$/ { if (finished) invalid = 1; finished = 1; next }
        {
            if (finished) invalid = 1
            for (field = 1; field <= NF; field++) {
                if ($field !~ /^[0-9]+$/ || $field + 0 > 255) invalid = 1
                if (++count <= 16405) bytes[count] = $field + 0
                else invalid = 1
            }
        }
        END {
            footer = "\nsubscription_exit:0\n"
            if (invalid || !finished || count <= length(footer) || count - length(footer) > 16384) exit 1
            for (i = 1; i <= length(footer); i++) {
                if (character(bytes[count - length(footer) + i]) != substr(footer, i, 1)) exit 1
            }
            count -= length(footer)
            position = 1
            whitespace()
            if (bytes[position] != 123 || !value(1)) exit 1
            whitespace()
            if (invalid || position != count + 1 || seenLogged != 1 || seenMethod != 1) exit 1
            exit 0
        }
        """#
}
