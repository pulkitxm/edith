from editor_acceptance_contracts import require
from editor_parity_fixtures import command
from editor_parity_pixels import calibrated_comparison, codec_control, offsets, reference_pixels


TARGET_GRADE = {"brightness": 0.002, "contrast": 1.02, "saturation": 1.035}


def visual_operations(manifest, dimensions, grade=TARGET_GRADE):
    operations = []
    for shot in manifest["shots"]:
        crop = shot.get("sourceCrop", shot.get("framingCrop"))
        if crop:
            operations.append({"crop": {"clipID": shot["name"], **crop}})
        effects = {"framing": "fullWidth" if shot["framing"] == "contain" else "fill",
                   "focalX": 0.5, "focalY": 0.5, "gradingMode": "ffmpeg709", **grade, "keyframes": []}
        if shot["framing"] == "contain":
            effects["background"] = {"blurRadius": 65 * dimensions[0] / manifest["width"]}
        if shot["zoom"]:
            effects["keyframes"] = [{"time": 0, "scale": 1, "interpolation": "linear"},
                                    {"time": shot["frames"] / 60, "scale": 1 + shot["zoom"], "interpolation": "linear"}]
        operations.append({"visualEffects": {"clipID": shot["name"], "effects": effects}})
    return operations


def photo_sample_frames(manifest):
    return {shot["startFrame"] + offset: (shot, offset) for shot in manifest["shots"] if shot["kind"] == "photo"
            for offset in (0, shot["frames"] // 2, shot["frames"] - 1)}


def check_motion_plan(project, manifest):
    for clip, shot in zip(project["timeline"]["clips"], manifest["shots"]):
        effects = clip["edithVisualEffects"]
        require(effects["gradingMode"] == "ffmpeg709", "Project lost its explicit grading semantics")
        require(all(effects[field] == value for field, value in TARGET_GRADE.items()),
                "Project changed the exact target brightness, contrast, or saturation")
        require(effects["focalX"] == effects["focalY"] == 0.5, "Zoom must use the center of the selected crop")
        crop = shot.get("sourceCrop", shot.get("framingCrop"))
        if crop:
            require(clip["cropRegion"] == crop, "Project changed its crop-before-zoom selection")
        keys = effects["keyframes"]
        if shot["zoom"]:
            require(len(keys) == 2 and keys[0]["time"] == 0 and keys[0]["scale"] == 1
                    and abs(keys[1]["time"] * 60 - shot["frames"]) < 1e-7 and keys[1]["scale"] == 1 + shot["zoom"]
                    and all(key["interpolation"] == "linear" for key in keys), "Photo motion keyframes differ from the exact frame-grid plan")
        else:
            require(not keys, "A static original unexpectedly acquired motion")
    return {"linearZoomPhotos": 24, "staticContainedPhotos": 18, "cropThenCenteredZoom": True, "exactKeyframeTimes": True}


def motion_reference(source, shot, width, height, frame, grade=TARGET_GRADE, frozen=False):
    require(shot["framing"] == "fill" and shot["kind"] == "photo", "Motion reference requires an original fill photo")
    crop = shot["framingCrop"]
    scale = 1 if frozen else 1 + shot["zoom"] * frame / shot["frames"]
    raster_width, raster_height = width * 4, height * 4
    zoom_width, zoom_height = round(raster_width * scale), round(raster_height * scale)
    filters = (f"crop=iw*{crop['width']}:ih*{crop['height']}:iw*{crop['x']}:ih*{crop['y']},"
               f"scale={zoom_width}:{zoom_height}:flags=lanczos,crop={raster_width}:{raster_height}:(iw-ow)/2:(ih-oh)/2,"
               "scale=in_range=full:out_range=limited:out_color_matrix=bt709,format=yuv444p,"
               f"eq=brightness={grade['brightness']}:contrast={grade['contrast']}:saturation={grade['saturation']},"
               "scale=in_range=limited:out_range=full:in_color_matrix=bt709,format=rgb24,"
               f"scale={width}:{height}:flags=lanczos")
    return command(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-i", source,
                    "-vf", filters, "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"])


def temporal_error(first, last, reference_first, reference_last, indices):
    return sum(abs((last[index + channel] - first[index + channel])
                   - (reference_last[index + channel] - reference_first[index + channel]))
               for index in indices for channel in range(3)) / (len(indices) * 3)


def check_photo_motion(actual, source, shot, width, height, exclusion=(0, 0, 0, 0), grade=TARGET_GRADE):
    frames = (0, shot["frames"] // 2, shot["frames"] - 1)
    require(set(actual) == set(frames), "Photo motion requires exact first, middle, and final visible frames")
    indices = offsets(width, height, exclude=[exclusion])
    if not shot["zoom"]:
        require(all(max(abs(a - b) for index in indices for a, b in zip(actual[0][index:index + 3], actual[frame][index:index + 3])) <= 1
                    for frame in frames[1:]), "A contained photo that must remain static moved")
        return {"staticFramesVerified": 3}
    references = {frame: motion_reference(source, shot, width, height, frame, grade) for frame in frames}
    positives = {frame: codec_control(value, width, height) for frame, value in references.items()}
    wrong_geometry = reference_pixels(source, width, height, framing="contain", **grade)
    first = calibrated_comparison(actual[0], references[0], positives[0], {"wrongFraming": wrong_geometry}, indices)
    comparisons = []
    for frame in frames[1:]:
        active = [index for index in indices if max(abs(references[frame][index + c] - references[0][index + c]) for c in range(3)) >= 12]
        require(len(active) >= 100, "Independent motion reference has too few informative pixels")
        positive = temporal_error(positives[0], positives[frame], references[0], references[frame], active)
        frozen = temporal_error(references[0], references[0], references[0], references[frame], active)
        require(frozen > max(1, positive) * 3, "Codec calibration cannot distinguish this motion from a frozen photo")
        tolerance = (positive + frozen) / 2
        measured = temporal_error(actual[0], actual[frame], references[0], references[frame], active)
        require(measured <= tolerance, f"Photo zoom differs from independent crop-then-zoom motion: {measured:.3f} > {tolerance:.3f}")
        comparisons.append({"sourceFrame": frame, "scale": 1 + shot["zoom"] * frame / shot["frames"],
                            "temporalError": measured, "codecControlError": positive, "frozenControlError": frozen,
                            "computedTolerance": tolerance, "informativePixels": len(active)})
    return {"firstFrame": first, "motionSamples": comparisons, "cropThenCenteredZoom": True}
