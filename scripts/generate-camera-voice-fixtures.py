from pathlib import Path
import onnx
from onnx import TensorProto, helper

root = Path(__file__).resolve().parents[1] / 'Extensions/virtualCamera/NativeRuntime/Tests/MeetingVoiceRuntimeTests/Fixtures'
root.mkdir(parents=True, exist_ok=True)

def save(name, inputs, output, shape, values):
    tensor = helper.make_tensor('synthetic-values', TensorProto.FLOAT, shape, values)
    graph = helper.make_graph([helper.make_node('Constant', [], [output], value=tensor)], name, inputs, [helper.make_tensor_value_info(output, TensorProto.FLOAT, shape)])
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 17)])
    model.ir_version = 9
    onnx.checker.check_model(model)
    onnx.save_model(model, root / name)

save('encoder.onnx', [helper.make_tensor_value_info('audio', TensorProto.FLOAT, [1, None])], 'units9', [1, 2, 256], [0.25] * 512)
save('voice.onnx', [helper.make_tensor_value_info('feats', TensorProto.FLOAT, [1, None, 256]), helper.make_tensor_value_info('p_len', TensorProto.INT64, [1]), helper.make_tensor_value_info('pitch', TensorProto.INT64, [1, None]), helper.make_tensor_value_info('pitchf', TensorProto.FLOAT, [1, None]), helper.make_tensor_value_info('sid', TensorProto.INT64, [1])], 'audio', [1, 1, 1280], [-1.5, 0.25, 1.5, 0.0] * 320)
