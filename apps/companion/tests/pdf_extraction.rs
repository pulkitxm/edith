fn synthetic_pdf(font: &str, content: &str) -> Vec<u8> {
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_string(),
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>".to_string(),
        format!("<< /Type /Font /Subtype /Type1 /BaseFont /{font} >>"),
        format!("<< /Length {} >>\nstream\n{content}\nendstream", content.len()),
    ];
    let mut result = b"%PDF-1.4\n".to_vec();
    let mut offsets = Vec::new();
    for (index, object) in objects.iter().enumerate() {
        offsets.push(result.len());
        result.extend(format!("{} 0 obj\n{object}\nendobj\n", index + 1).as_bytes());
    }
    let xref = result.len();
    result.extend(format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1).as_bytes());
    for offset in offsets {
        result.extend(format!("{offset:010} 00000 n \n").as_bytes());
    }
    result.extend(
        format!(
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
            objects.len() + 1
        )
        .as_bytes(),
    );
    result
}

#[test]
fn standard_fonts_preserve_text_and_vertical_layout() {
    for font in ["Helvetica", "Times-Roman", "Courier"] {
        let data = synthetic_pdf(
            font,
            "BT /F1 12 Tf 72 720 Td (Mock heading) Tj 0 -24 Td (Mock body) Tj ET",
        );
        let text = pdf_extract::extract_text_from_mem(&data).expect("synthetic standard-font PDF");
        let rows = text
            .lines()
            .map(str::trim)
            .filter(|row| !row.is_empty())
            .collect::<Vec<_>>();
        assert_eq!(rows, ["Mock heading", "Mock body"], "{font}");
    }
}

#[test]
fn empty_page_preserves_the_ingestion_empty_text_contract() {
    let data = synthetic_pdf("Helvetica", "");
    let text = pdf_extract::extract_text_from_mem(&data).expect("synthetic empty PDF");
    assert!(text.trim().is_empty());
}

#[test]
fn malformed_pdf_returns_an_error() {
    assert!(pdf_extract::extract_text_from_mem(b"synthetic malformed PDF").is_err());
}
