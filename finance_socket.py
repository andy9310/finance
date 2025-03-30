# ✅ Python 版 WebSocket 訂閱報價 + 儲存進資料庫 + 簡易策略觸發
# 使用 websocket-client 套件訂閱 Binance 的即時報價（BTC/USDT）
# 並將報價存入 SQLite 資料庫，並執行簡單策略示範（價格超過 70,000 USD 時觸發）

import websocket
import json
import sqlite3
from datetime import datetime

DB_FILE = 'price_data.db'

# 建立 SQLite 資料庫
conn = sqlite3.connect(DB_FILE)
cursor = conn.cursor()
cursor.execute('''
    CREATE TABLE IF NOT EXISTS btc_price (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT,
        price REAL
    )
''')
conn.commit()

def store_price(price):
    timestamp = datetime.utcnow().isoformat()
    cursor.execute("INSERT INTO btc_price (timestamp, price) VALUES (?, ?)", (timestamp, price))
    conn.commit()

    # 簡單策略：當價格超過 70,000 時提示
    if price > 70000:
        print("🚀 策略觸發：BTC 價格突破 70,000 USD！")

def on_message(ws, message):
    data = json.loads(message)
    price = float(data['c'])
    print(f"即時價格更新：{data['s']} 價格 {price}")
    store_price(price)

def on_error(ws, error):
    print("錯誤：", error)

def on_close(ws, close_status_code, close_msg):
    print("連線關閉")

def on_open(ws):
    print("WebSocket 連線成功，訂閱 BTC/USDT 報價")
    payload = {
        "method": "SUBSCRIBE",
        "params": ["btcusdt@ticker"],
        "id": 1
    }
    ws.send(json.dumps(payload))

if __name__ == "__main__":
    url = "wss://stream.binance.com:9443/ws"
    ws = websocket.WebSocketApp(
        url,
        on_open=on_open,
        on_message=on_message,
        on_error=on_error,
        on_close=on_close
    )
    try:
        ws.run_forever()
    except KeyboardInterrupt:
        print("手動中斷連線")
    finally:
        conn.close()
