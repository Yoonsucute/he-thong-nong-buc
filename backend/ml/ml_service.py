"""Heat Index và LSTM; không thay dữ liệu thật bằng số giả lập."""
import math
import os
import threading
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
MODEL_PATH = os.path.join(BASE_DIR, "heat_index_lstm.keras")
SCALER_PATH = os.path.join(BASE_DIR, "scaler.pkl")
model = None
scaler = None
_model_lock = threading.Lock()

class ForecastUnavailable(Exception):
    pass

def calculate_heat_index(T, R):
    """Giữ công thức chỉ số hiện có của đồ án, đơn vị °C."""
    T_F = T*1.8+32
    hi_f = 0.5*(T_F+61.0+((T_F-68.0)*1.2)+(R*0.094))
    if hi_f >= 80:
        hi_f = (-42.379+2.04901523*T_F+10.14333127*R
                -0.22475541*T_F*R-0.00683783*T_F*T_F-0.05481717*R*R
                +0.00122874*T_F*T_F*R+0.00085282*T_F*R*R-0.00000199*T_F*T_F*R*R)
    return round((hi_f-32)/1.8, 1)

def run_lstm_forecast(recent_logs):
    """Nhận 12 giá trị trung bình giờ mới nhất trước, trả 5 giờ tới."""
    global model, scaler
    if len(recent_logs) != 12:
        raise ForecastUnavailable("Cần đủ 12 giờ dữ liệu để chạy mô hình LSTM.")
    with _model_lock:
        try:
            import numpy as np
            if model is None or scaler is None:
                if not os.path.isfile(MODEL_PATH) or not os.path.isfile(SCALER_PATH):
                    raise ForecastUnavailable("Chưa có tệp mô hình LSTM hoặc bộ chuẩn hóa.")
                import joblib
                import tensorflow as tf
                model = tf.keras.models.load_model(MODEL_PATH, compile=False)
                scaler = joblib.load(SCALER_PATH)
            # Heat Index là đặc trưng của mô hình. Lấy trung bình chỉ số đã tính
            # thay vì tính lại từ nhiệt độ/độ ẩm trung bình (công thức phi tuyến).
            series = [float(row["heat_index"]) if row.get("heat_index") is not None
                      else calculate_heat_index(float(row["temperature"]), float(row["humidity"]))
                      for row in reversed(recent_logs)]
            if not all(math.isfinite(value) for value in series):
                raise ForecastUnavailable("Dữ liệu đầu vào mô hình không hợp lệ.")
            source = np.asarray(series).reshape(12, 1)
            scaled = scaler.transform(source).reshape(1, 12, 1)
            prediction = np.asarray(model.predict(scaled, verbose=0)).reshape(-1)
            if prediction.size != 5:
                raise ForecastUnavailable("Mô hình phải xuất đúng 5 giá trị dự báo.")
            values = scaler.inverse_transform(prediction.reshape(-1, 1)).reshape(-1)
            if not all(math.isfinite(float(value)) for value in values):
                raise ForecastUnavailable("Mô hình trả về dữ liệu không hợp lệ.")
            return [round(float(value), 1) for value in values]
        except ForecastUnavailable:
            raise
        except Exception as error:
            raise ForecastUnavailable("Không tải hoặc chạy được mô hình LSTM. Kiểm tra TensorFlow, scaler và tệp mô hình.") from error
