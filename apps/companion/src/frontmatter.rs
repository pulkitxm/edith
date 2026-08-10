use chrono::{DateTime, NaiveDate, Utc};

#[derive(Debug, Eq, PartialEq)]
pub struct FrontMatter {
    pub date: Option<DateTime<Utc>>,
    pub title: Option<String>,
}

fn scalar(value: &str) -> &str {
    let trimmed = value.trim();
    let bytes = trimmed.as_bytes();
    if bytes.len() >= 2 && (bytes[0] == b'\'' || bytes[0] == b'"') && bytes.last() == bytes.first()
    {
        return trimmed[1..trimmed.len() - 1].trim();
    }
    trimmed
}

fn parsed_date(value: &str) -> Option<DateTime<Utc>> {
    if value.len() == 10 {
        if let Ok(date) = NaiveDate::parse_from_str(value, "%Y-%m-%d") {
            return date.and_hms_opt(0, 0, 0).map(|date| date.and_utc());
        }
    }
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|date| date.with_timezone(&Utc))
}

pub fn body_without_front_matter(text: &str) -> &str {
    let mut rest = text;
    let Some(first) = rest.split_inclusive('\n').next() else {
        return text;
    };
    if first.trim() != "---" {
        return text;
    }
    rest = &rest[first.len()..];
    let mut offset = first.len();
    for line in rest.split_inclusive('\n') {
        offset += line.len();
        if line.trim() == "---" {
            return text[offset..].trim_start_matches('\n');
        }
    }
    text
}

pub fn parse_front_matter(text: &str) -> FrontMatter {
    let lines = text.lines().collect::<Vec<_>>();
    let mut body_start = 0;
    let mut date = None;
    let mut date_seen = false;
    let mut title = None;

    if lines.first().is_some_and(|line| line.trim() == "---") {
        if let Some(closing_index) = lines
            .iter()
            .enumerate()
            .skip(1)
            .find_map(|(index, line)| (line.trim() == "---").then_some(index))
        {
            body_start = closing_index + 1;

            for line in &lines[1..closing_index] {
                let Some((key, value)) = line.split_once(':') else {
                    continue;
                };
                if key.trim().is_empty() {
                    continue;
                }
                let key = key.trim();
                let value = scalar(value);

                if key == "title" && !value.is_empty() {
                    title = Some(value.to_owned());
                }

                if !date_seen
                    && matches!(key, "date" | "created" | "occurred_at")
                    && !value.is_empty()
                {
                    date_seen = true;
                    date = parsed_date(value);
                }
            }
        }
    }

    if title.is_none() {
        title = lines[body_start..]
            .iter()
            .find_map(|line| line.strip_prefix("# "))
            .map(str::trim)
            .filter(|heading| !heading.is_empty())
            .map(str::to_owned);
    }

    FrontMatter { date, title }
}

#[cfg(test)]
mod tests {
    use super::{body_without_front_matter, parse_front_matter};

    #[test]
    fn strips_front_matter_from_body() {
        assert_eq!(
            body_without_front_matter("---\ndate: 2026-08-09\n---\n# Note\n\nBody."),
            "# Note\n\nBody."
        );
        assert_eq!(
            body_without_front_matter("# Note\n\nBody."),
            "# Note\n\nBody."
        );
        assert_eq!(body_without_front_matter("---\nunclosed"), "---\nunclosed");
    }

    #[test]
    fn parses_plain_date() {
        let result = parse_front_matter("---\ndate: 2026-08-09\n---\n# Note");
        assert_eq!(
            result.date.map(|date| date.to_rfc3339()),
            Some("2026-08-09T00:00:00+00:00".to_owned())
        );
    }

    #[test]
    fn parses_rfc3339_created() {
        let result = parse_front_matter("---\ncreated: 2026-08-09T10:15:30+05:30\n---");
        assert_eq!(
            result.date.map(|date| date.to_rfc3339()),
            Some("2026-08-09T04:45:30+00:00".to_owned())
        );
    }

    #[test]
    fn uses_heading_without_front_matter() {
        let result = parse_front_matter("intro\n# First\n# Second");
        assert_eq!(result.title.as_deref(), Some("First"));
    }

    #[test]
    fn title_key_precedes_heading() {
        let result = parse_front_matter("---\ntitle: 'Front Matter'\n---\n# Heading");
        assert_eq!(result.title.as_deref(), Some("Front Matter"));
    }

    #[test]
    fn unparseable_date_is_none() {
        let result = parse_front_matter("---\ndate: someday\ncreated: 2026-08-09\n---");
        assert_eq!(result.date, None);
    }
}
