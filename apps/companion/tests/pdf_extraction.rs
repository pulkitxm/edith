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

fn numbers(values: &[i64]) -> pdf_extract::Object {
    pdf_extract::Object::Array(
        values
            .iter()
            .copied()
            .map(pdf_extract::Object::Integer)
            .collect(),
    )
}

fn color_pdf(space: pdf_extract::Object, function: Option<pdf_extract::Object>) -> Vec<u8> {
    use pdf_extract::{Dictionary, Document, Object};
    let content = "/MockColor cs 0.25 scn 0 0 5 5 re f q /DeviceGray cs 0.75 scn 5 0 5 5 re f Q 10 0 5 5 re f BT /F1 12 Tf 72 720 Td (Mock color text) Tj ET";
    let mut document =
        Document::load_mem(&synthetic_pdf("Helvetica", content)).expect("synthetic color document");
    let space = if let Some(function) = function {
        let function_id = document.add_object(function);
        Object::Array(vec![
            Object::Name(b"Separation".to_vec()),
            Object::Name(b"MockInk".to_vec()),
            space,
            Object::Reference(function_id),
        ])
    } else {
        space
    };
    let mut colors = Dictionary::new();
    colors.set("MockColor", space);
    let page = document
        .get_object_mut((3, 0))
        .expect("synthetic page")
        .as_dict_mut()
        .expect("page dictionary");
    page.get_mut(b"Resources")
        .expect("synthetic resources")
        .as_dict_mut()
        .expect("resource dictionary")
        .set("ColorSpace", colors);
    let mut result = Vec::new();
    document.save_to(&mut result).expect("synthetic color PDF");
    result
}

#[derive(Default)]
struct ColorOutput {
    colors: Vec<(String, Vec<f64>)>,
    text: String,
}

impl pdf_extract::OutputDev for ColorOutput {
    fn begin_page(
        &mut self,
        _: u32,
        _: &pdf_extract::MediaBox,
        _: Option<(f64, f64, f64, f64)>,
    ) -> Result<(), pdf_extract::OutputError> {
        Ok(())
    }
    fn end_page(&mut self) -> Result<(), pdf_extract::OutputError> {
        Ok(())
    }
    fn output_character(
        &mut self,
        _: &pdf_extract::Transform,
        _: f64,
        _: f64,
        _: f64,
        character: &str,
    ) -> Result<(), pdf_extract::OutputError> {
        self.text.push_str(character);
        Ok(())
    }
    fn begin_word(&mut self) -> Result<(), pdf_extract::OutputError> {
        Ok(())
    }
    fn end_word(&mut self) -> Result<(), pdf_extract::OutputError> {
        Ok(())
    }
    fn end_line(&mut self) -> Result<(), pdf_extract::OutputError> {
        Ok(())
    }
    fn fill(
        &mut self,
        _: &pdf_extract::Transform,
        space: &pdf_extract::ColorSpace,
        color: &[f64],
        _: &pdf_extract::Path,
    ) -> Result<(), pdf_extract::OutputError> {
        let description = match space.clone() {
            pdf_extract::ColorSpace::CalGray(value) => format!("{value:?}"),
            pdf_extract::ColorSpace::CalRGB(value) => format!("{value:?}"),
            pdf_extract::ColorSpace::Lab(value) => format!("{value:?}"),
            pdf_extract::ColorSpace::Separation(_) => "Separation".to_string(),
            pdf_extract::ColorSpace::DeviceGray => "DeviceGray".to_string(),
            _ => panic!("unexpected synthetic color space"),
        };
        self.colors.push((description, color.to_vec()));
        Ok(())
    }
}

fn color_output(data: &[u8]) -> ColorOutput {
    let document = pdf_extract::Document::load_mem(data).expect("synthetic color input");
    let mut output = ColorOutput::default();
    pdf_extract::output_doc(&document, &mut output).expect("synthetic color output");
    output
}

fn calibrated_space(name: &str) -> pdf_extract::Object {
    use pdf_extract::{Dictionary, Object};
    let mut values = Dictionary::new();
    values.set("WhitePoint", numbers(&[1, 1, 1]));
    values.set("BackPoint", numbers(&[0, 0, 0]));
    match name {
        "CalGray" => values.set("Gamma", 2),
        "CalRGB" => {
            values.set("Gamma", numbers(&[2, 2, 2]));
            values.set("Matrix", numbers(&[1, 0, 0, 0, 1, 0, 0, 0, 1]));
        }
        "Lab" => values.set("Range", numbers(&[-100, 100, -100, 100])),
        _ => panic!("unexpected synthetic calibration"),
    }
    Object::Array(vec![
        Object::Name(name.as_bytes().to_vec()),
        Object::Dictionary(values),
    ])
}

#[test]
fn calibrated_fields_and_saved_graphics_state_keep_original_output() {
    for (name, expected) in [
        (
            "CalGray",
            "CalGray { white_point: [1.0, 1.0, 1.0], black_point: Some([0.0, 0.0, 0.0]), gamma: Some(2.0) }",
        ),
        (
            "CalRGB",
            "CalRGB { white_point: [1.0, 1.0, 1.0], black_point: Some([0.0, 0.0, 0.0]), gamma: Some([2.0, 2.0, 2.0]), matrix: Some([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]) }",
        ),
        (
            "Lab",
            "Lab { white_point: [1.0, 1.0, 1.0], black_point: Some([0.0, 0.0, 0.0]), range: Some([-100.0, 100.0, -100.0, 100.0]) }",
        ),
    ] {
        let output = color_output(&color_pdf(calibrated_space(name), None));
        assert_eq!(
            output.colors,
            [
                (expected.to_string(), vec![0.25]),
                ("DeviceGray".to_string(), vec![0.75]),
                (expected.to_string(), vec![0.25])
            ],
            "{name}"
        );
        assert_eq!(output.text, "Mock color text", "{name}");
    }
}

fn tint_function(kind: i64) -> pdf_extract::Object {
    use pdf_extract::{Dictionary, Object, Stream};
    let mut values = Dictionary::new();
    values.set("FunctionType", kind);
    values.set("Domain", numbers(&[0, 1]));
    values.set("Range", numbers(&[0, 1, 0, 1, 0, 1]));
    match kind {
        0 => {
            values.set("Size", numbers(&[2]));
            values.set("BitsPerSample", 8);
            Object::Stream(Stream::new(values, vec![0, 0, 0, 255, 255, 255]))
        }
        2 => {
            values.set("C0", numbers(&[0, 0, 0]));
            values.set("C1", numbers(&[1, 1, 1]));
            values.set("N", 1);
            Object::Dictionary(values)
        }
        3 => Object::Dictionary(values),
        4 => Object::Stream(Stream::new(values, b"{ dup dup }".to_vec())),
        _ => panic!("unexpected synthetic tint function"),
    }
}

#[test]
fn separation_function_variants_keep_saved_state_and_text() {
    for kind in [0, 2, 3, 4] {
        let data = color_pdf(
            pdf_extract::Object::Name(b"DeviceRGB".to_vec()),
            Some(tint_function(kind)),
        );
        let output = color_output(&data);
        assert_eq!(
            output.colors,
            [
                ("Separation".to_string(), vec![0.25]),
                ("DeviceGray".to_string(), vec![0.75]),
                ("Separation".to_string(), vec![0.25])
            ],
            "function {kind}"
        );
        assert_eq!(output.text, "Mock color text", "function {kind}");
    }
}

#[test]
fn missing_calibration_and_function_parameters_keep_original_rejection() {
    use pdf_extract::{Dictionary, Object};
    let invalid_space = Object::Array(vec![
        Object::Name(b"CalGray".to_vec()),
        Object::Dictionary(Dictionary::new()),
    ]);
    let data = color_pdf(invalid_space, None);
    assert!(std::panic::catch_unwind(|| color_output(&data)).is_err());
    let mut function = Dictionary::new();
    function.set("FunctionType", 2);
    let data = color_pdf(
        Object::Name(b"DeviceRGB".to_vec()),
        Some(Object::Dictionary(function)),
    );
    assert!(std::panic::catch_unwind(|| color_output(&data)).is_err());
}

#[test]
fn type3_document_parsing_and_width_validation_remain_original() {
    use pdf_extract::{Document, Object};
    let mut document = Document::load_mem(&synthetic_pdf(
        "Helvetica",
        "BT /F1 12 Tf 72 720 Td (A) Tj ET",
    ))
    .expect("synthetic Type3 document");
    let font = document
        .get_object_mut((4, 0))
        .expect("synthetic font")
        .as_dict_mut()
        .expect("font dictionary");
    font.set("Subtype", Object::Name(b"Type3".to_vec()));
    font.set("Encoding", Object::Name(b"WinAnsiEncoding".to_vec()));
    font.set("FirstChar", 65);
    font.set("LastChar", 65);
    font.set("Widths", numbers(&[600]));
    let mut data = Vec::new();
    document.save_to(&mut data).expect("synthetic Type3 PDF");
    assert_eq!(
        pdf_extract::extract_text_from_mem(&data)
            .expect("Type3 font text")
            .trim(),
        "A"
    );
    document
        .get_object_mut((4, 0))
        .expect("synthetic font")
        .as_dict_mut()
        .expect("font dictionary")
        .set("LastChar", 66);
    let mut invalid = Vec::new();
    document
        .save_to(&mut invalid)
        .expect("synthetic invalid widths");
    assert!(std::panic::catch_unwind(|| pdf_extract::extract_text_from_mem(&invalid)).is_err());
}
