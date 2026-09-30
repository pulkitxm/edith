from editor_acceptance_contracts import require
from editor_parity_adapters import CAPTION_BOUNDS, CAPTION_EXCLUSION, caption_style
from editor_parity_checks import check_captions, check_mastered_audio, check_video, picture_sample_frames
from editor_parity_fixtures import checksum, fixture_path
from editor_parity_glyphs import check_caption_identity, glyph_control_canvas, reference_glyphs
from editor_parity_grade import check_target_grade
from editor_parity_motion import TARGET_GRADE, check_photo_motion, photo_sample_frames
from editor_parity_native import srgb_frame_stream, srgb_frames
from editor_parity_pixels import check_caption_pixels, check_photo_pixels, codec_control
from editor_parity_review import frame_pixels
from editor_parity_style import check_caption_placement, check_styled_caption


def caption_frame_checks(actual, background, shot, dimensions, directory):
    width, height = dimensions
    scale = width / 2160
    reference = reference_glyphs(shot["caption"], "Arial", "Bold Italic", shot["fontSize"] * scale, directory)
    control = glyph_control_canvas(reference, width, height, round(2780 * scale), round(150 * scale))
    positive = codec_control(control, width, height)
    glyphs = check_caption_identity(actual, positive, bytes(width * height * 3), width, height, CAPTION_BOUNDS, reference)
    geometry = check_caption_pixels(actual, background, width, height, CAPTION_BOUNDS)
    placement = check_caption_placement(actual, background, shot["caption"], caption_style(shot["fontSize"]), width, height, CAPTION_BOUNDS)
    report = {"glyphs": glyphs, "geometry": geometry, "absolutePlacement": placement}
    if width == 2160 and height == 3840:
        report["styledPixels"] = check_styled_caption(actual, background, shot["caption"], caption_style(shot["fontSize"]), width, height)
    return report


def caption_review(edit, visual, styled, workspace, manifest, styles, dimensions):
    before = {path: checksum(path) for path in (visual, styled)}
    report = check_captions(edit("captions", "list", styled, "--json"), manifest, styles)
    directory = workspace / "caption-review"
    directory.mkdir()
    checks = []
    for shot in manifest["shots"]:
        frame = shot["startFrame"] + shot["frames"] // 2
        actual = frame_pixels(edit, styled, frame, directory / f"{shot['name']}.png", dimensions)
        background = frame_pixels(edit, visual, frame, directory / f"{shot['name']}-background.png", dimensions)
        checks.append({"source": shot["name"], "frame": frame,
                       "checks": caption_frame_checks(actual, background, shot, dimensions, directory / f"glyph-{shot['name']}")})
    require(all(checksum(path) == value for path, value in before.items()), "Caption review modified an editable project")
    return {**report, "independentFrames": checks}


def delivery(edit, project, visual, output, workspace, fixture, manifest, dimensions, reference, codec):
    before = checksum(project)
    report = edit("render", project, "--output", output, "--codec", "h264", "--bit-rate", "80000000",
                  "--audio-codec", "aac", "--audio-bit-rate", "320000", "--audio-sample-rate", "48000",
                  "--audio-channels", "2", "--progress", "--json")
    video = check_video(output, dimensions, manifest)
    video_samples = picture_sample_frames(manifest)
    video_frames = srgb_frames(output, 270, 480, list(video_samples))
    video["targetGrades"] = [{"outputFrame": frame, "sourceFrame": source_frame,
                              "check": check_target_grade(video_frames[frame], fixture_path(fixture, shot["path"]), shot, 270, 480,
                                                          CAPTION_EXCLUSION, source_frame)}
                             for frame, (shot, source_frame) in video_samples.items()]
    audio = check_mastered_audio(output, fixture_path(fixture, manifest["music"]["path"]), manifest, reference, codec, exact_samples=False)
    selected = photo_sample_frames(manifest)
    frames = srgb_frames(output, 270, 480, list(selected))
    photos = []
    for shot in (value for value in manifest["shots"] if value["kind"] == "photo"):
        actual = {offset: frames[shot["startFrame"] + offset] for offset in (0, shot["frames"] // 2, shot["frames"] - 1)}
        source = fixture_path(fixture, shot["path"])
        if shot["zoom"]:
            check = check_photo_motion(actual, source, shot, 270, 480, CAPTION_EXCLUSION)
        else:
            check = {str(frame): check_photo_pixels(pixels, source, (shot["width"], shot["height"]), 270, 480, 65 / 8,
                                                    CAPTION_EXCLUSION, TARGET_GRADE, shot.get("sourceCrop"), check_grade=False)
                     for frame, pixels in actual.items()}
        photos.append({"source": shot["name"], "checks": check,
                       "targetGrade": check_target_grade(actual[0], source, shot, 270, 480, CAPTION_EXCLUSION)})
    directory = workspace / "delivery-caption-checks"
    directory.mkdir()
    captions = []
    selections = {shot["startFrame"] + shot["frames"] // 2: shot for shot in manifest["shots"]}
    with srgb_frame_stream(output, dimensions, selections) as samples:
        for frame, actual in samples:
            shot = selections[frame]
            background = frame_pixels(edit, visual, frame, directory / f"background-{shot['name']}.png", dimensions)
            captions.append({"source": shot["name"], "frame": frame,
                             "checks": caption_frame_checks(actual, background, shot, dimensions, directory / f"glyph-{shot['name']}")})
    require(checksum(project) == before, "Final export changed its editable project")
    return {"nativeReport": report, "independentVideo": video, "independentAudio": audio,
            "appearanceComparisonDomain": "ColorSync sRGB from native decoded buffer color attachments",
            "photoFrames": photos, "captionFrames": captions, "projectPreserved": True}
