import tensorflow as tf

interpreter = tf.lite.Interpreter(model_path="assets/model/morphology_transformer_final.tflite")
interpreter.allocate_tensors()

input_details = interpreter.get_input_details()
output_details = interpreter.get_output_details()

print("INPUT:", input_details)
print("OUTPUT:", output_details)