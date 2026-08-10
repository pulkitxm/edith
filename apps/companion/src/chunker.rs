const MAX_CHARS: usize = 1600;

fn paragraphs(text: &str) -> Vec<&str> {
    let mut paragraphs = Vec::new();
    let mut paragraph_start = None;
    let mut paragraph_end = 0;
    let mut offset = 0;

    for line in text.split_inclusive('\n') {
        let content = line.strip_suffix('\n').unwrap_or(line);
        let content = content.strip_suffix('\r').unwrap_or(content);
        let content_end = offset + content.len();
        if content.trim().is_empty() {
            if let Some(start) = paragraph_start.take() {
                paragraphs.push(&text[start..paragraph_end]);
            }
        } else {
            paragraph_start.get_or_insert(offset);
            paragraph_end = content_end;
        }
        offset += line.len();
    }

    if let Some(start) = paragraph_start {
        paragraphs.push(&text[start..paragraph_end]);
    }

    paragraphs
}

fn push_hard_splits(paragraph: &str, chunks: &mut Vec<String>) {
    let mut start = 0;
    let mut count = 0;
    for (index, _) in paragraph.char_indices() {
        if count == MAX_CHARS {
            let chunk = &paragraph[start..index];
            if !chunk.trim().is_empty() {
                chunks.push(chunk.to_owned());
            }
            start = index;
            count = 0;
        }
        count += 1;
    }
    let chunk = &paragraph[start..];
    if !chunk.trim().is_empty() {
        chunks.push(chunk.to_owned());
    }
}

pub fn chunk_text(text: &str) -> Vec<String> {
    let mut chunks = Vec::new();
    let mut packed = String::new();
    let mut packed_chars = 0;

    for paragraph in paragraphs(text) {
        let paragraph_chars = paragraph.chars().count();
        if paragraph_chars > MAX_CHARS {
            if !packed.trim().is_empty() {
                chunks.push(std::mem::take(&mut packed));
                packed_chars = 0;
            }
            push_hard_splits(paragraph, &mut chunks);
            continue;
        }

        let separator_chars = usize::from(!packed.is_empty()) * 2;
        if packed_chars + separator_chars + paragraph_chars > MAX_CHARS {
            if !packed.trim().is_empty() {
                chunks.push(std::mem::take(&mut packed));
            }
            packed_chars = 0;
        }
        if !packed.is_empty() {
            packed.push_str("\n\n");
            packed_chars += 2;
        }
        packed.push_str(paragraph);
        packed_chars += paragraph_chars;
    }

    if !packed.trim().is_empty() {
        chunks.push(packed);
    }

    chunks
}

#[cfg(test)]
mod tests {
    use super::{MAX_CHARS, chunk_text};

    #[test]
    fn short_document_is_one_chunk() {
        assert_eq!(chunk_text("alpha\n\nbeta"), vec!["alpha\n\nbeta"]);
    }

    #[test]
    fn multi_paragraph_packing_respects_the_cap() {
        let first = "a".repeat(900);
        let second = "b".repeat(500);
        let third = "c".repeat(300);
        let text = format!("{first}\n\n{second}\n\n{third}");
        let chunks = chunk_text(&text);
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[0], format!("{first}\n\n{second}"));
        assert_eq!(chunks[1], third);
        assert!(
            chunks
                .iter()
                .all(|chunk| chunk.chars().count() <= MAX_CHARS)
        );
    }

    #[test]
    fn oversized_paragraph_is_hard_split() {
        let text = "é".repeat(MAX_CHARS + 1);
        let chunks = chunk_text(&text);
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[0].chars().count(), MAX_CHARS);
        assert_eq!(chunks[1], "é");
        assert_eq!(chunks.concat(), text);
    }

    #[test]
    fn empty_input_yields_no_chunks() {
        assert!(chunk_text(" \n\n\t\n").is_empty());
    }
}
