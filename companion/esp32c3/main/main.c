#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"

#include "esp_err.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "driver/uart.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"

#include "host/ble_hs.h"
#include "host/ble_hs_id.h"
#include "host/ble_att.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"

#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "os/os_mbuf.h"

/*
 * ESP32-C3 -> FPGA
 *
 * GPIO21 TX -> FPGA C18 RX
 * GPIO20 RX <- FPGA C19 TX
 * GND       -> FPGA GND
 *
 * UART: 115200 / 8N1 / 3.3V
 *
 * ESP-IDF 控制台使用 USB Serial/JTAG，
 * 不要使用 GPIO20/21 作为日志串口。
 *
 * BLE:
 * Service: 6e400001-b5a3-f393-e0a9-e50e24dcca9e
 * RX:      6e400002-b5a3-f393-e0a9-e50e24dcca9e
 *          READ / WRITE / WRITE WITHOUT RESPONSE
 * TX:      6e400003-b5a3-f393-e0a9-e50e24dcca9e
 *          READ / NOTIFY
 *
 * 支持发送：
 * 1. HEX模式：A5 90 3C 64 6D
 * 2. 文本模式："A5 90 3C 64 6D"
 * 3. 文本模式："A5903C646D"
 * 4. 文本模式："0xA5903C646D"
 *
 * UART OK 5 仅代表 ESP 完成 UART 发送，
 * 不代表 FPGA 已确认接收。
 */

#define DEVICE_NAME         "FPGA-BLE-FIX3"

#define FPGA_UART           UART_NUM_1
#define FPGA_RX_PIN         20
#define FPGA_TX_PIN         21
#define FPGA_BAUD           115200

#define WRITE_MAX           244
#define WRITE_QUEUE_LEN     16
#define NOTIFY_BYTES        20

static const char *TAG = "BLE_BRIDGE";

static const ble_uuid128_t service_uuid = BLE_UUID128_INIT(
    0x9e, 0xca, 0xdc, 0x24,
    0x0e, 0xe5, 0xa9, 0xe0,
    0x93, 0xf3, 0xa3, 0xb5,
    0x01, 0x00, 0x40, 0x6e
);

static const ble_uuid128_t rx_uuid = BLE_UUID128_INIT(
    0x9e, 0xca, 0xdc, 0x24,
    0x0e, 0xe5, 0xa9, 0xe0,
    0x93, 0xf3, 0xa3, 0xb5,
    0x02, 0x00, 0x40, 0x6e
);

static const ble_uuid128_t tx_uuid = BLE_UUID128_INIT(
    0x9e, 0xca, 0xdc, 0x24,
    0x0e, 0xe5, 0xa9, 0xe0,
    0x93, 0xf3, 0xa3, 0xb5,
    0x03, 0x00, 0x40, 0x6e
);

typedef struct {
    uint16_t length;
    uint8_t data[WRITE_MAX];
} uart_packet_t;

static QueueHandle_t write_queue;

static uint16_t rx_value_handle;
static uint16_t tx_value_handle;
static uint8_t own_addr_type;

static portMUX_TYPE state_lock = portMUX_INITIALIZER_UNLOCKED;

static uint16_t connection_handle = BLE_HS_CONN_HANDLE_NONE;
static bool notifications_enabled;

static unsigned long ble_rx_count;
static unsigned uart_tx_length;

static void advertise(void);
static int gap_event(struct ble_gap_event *event, void *arg);

/* NimBLE 返回码不是 esp_err_t，单独检查。 */
static void check_ble(int rc, const char *operation)
{
    if (rc != 0) {
        ESP_LOGE(TAG, "%s failed: rc=%d", operation, rc);
        abort();
    }
}

static void set_link_state(uint16_t connection, bool subscribed)
{
    portENTER_CRITICAL(&state_lock);
    connection_handle = connection;
    notifications_enabled = subscribed;
    portEXIT_CRITICAL(&state_lock);
}

static bool notification_target(uint16_t *connection)
{
    bool ready;

    portENTER_CRITICAL(&state_lock);

    *connection = connection_handle;
    ready = notifications_enabled &&
            connection_handle != BLE_HS_CONN_HANDLE_NONE;

    portEXIT_CRITICAL(&state_lock);

    return ready;
}

/*
 * 最多20字节，兼容默认 ATT MTU=23。
 * 未开启通知时不发送，状态仍然可以通过 READ 读取。
 */
static void notify_phone(const void *data, uint16_t length)
{
    uint16_t connection;

    if (length == 0 || length > NOTIFY_BYTES) {
        return;
    }

    if (!notification_target(&connection)) {
        return;
    }

    struct os_mbuf *om = ble_hs_mbuf_from_flat(data, length);
    if (om == NULL) {
        ESP_LOGW(TAG, "Notify buffer unavailable");
        return;
    }

    /*
     * NimBLE 接管 om。
     * 无论返回成功还是失败，都不要再次释放。
     */
    int rc = ble_gatts_notify_custom(
        connection, tx_value_handle, om);

    if (rc != 0) {
        ESP_LOGW(TAG, "Notify failed: rc=%d", rc);
    }
}

static int hex_digit(uint8_t c)
{
    if (c >= '0' && c <= '9') {
        return c - '0';
    }

    if (c >= 'a' && c <= 'f') {
        return c - 'a' + 10;
    }

    if (c >= 'A' && c <= 'F') {
        return c - 'A' + 10;
    }

    return -1;
}

static bool text_space(uint8_t c)
{
    return c == ' ' || c == '\t' ||
           c == '\r' || c == '\n';
}

/*
 * 原始二进制数据保持不变。
 * 以 A5/a5 或 0x/0X 开头的文本转换为二进制。
 *
 * 每次 BLE 写入应包含完整的 HEX 文本。
 */
static bool normalize_packet(uart_packet_t *packet)
{
    uint16_t first = 0;

    while (first < packet->length &&
           text_space(packet->data[first])) {
        ++first;
    }

    if (first + 1 >= packet->length) {
        return true;
    }

    bool prefix =
        packet->data[first] == '0' &&
        (packet->data[first + 1] == 'x' ||
         packet->data[first + 1] == 'X');

    bool starts_a5 =
        (packet->data[first] == 'A' ||
         packet->data[first] == 'a') &&
        packet->data[first + 1] == '5';

    if (!prefix && !starts_a5) {
        return true;
    }

    uint16_t output = 0;
    int high = -1;

    for (uint16_t i = first + (prefix ? 2 : 0);
         i < packet->length; ++i) {
        uint8_t c = packet->data[i];

        if (text_space(c)) {
            /* 不允许将一个字节拆成 "9 0"。 */
            if (high >= 0) {
                return false;
            }
            continue;
        }

        int value = hex_digit(c);

        if (value < 0) {
            return false;
        }

        if (high < 0) {
            high = value;
        } else {
            packet->data[output++] =
                (uint8_t)((high << 4) | value);
            high = -1;
        }
    }

    if (high >= 0 || output == 0) {
        return false;
    }

    packet->length = output;
    return true;
}

/* 读取002或003均返回状态。 */
static int read_status(uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *ctxt)
{
    unsigned long received;
    unsigned sent;

    portENTER_CRITICAL(&state_lock);
    received = ble_rx_count;
    sent = uart_tx_length;
    portEXIT_CRITICAL(&state_lock);

    char status[21];

    int length = snprintf(
        status, sizeof(status),
        "F3 R=%lu U=%u",
        received % 1000000UL,
        sent);

    if (length < 0 || length >= (int)sizeof(status)) {
        return BLE_ATT_ERR_UNLIKELY;
    }

    ESP_LOGI(TAG, "READ handle=0x%04X: %s",
             (unsigned)attr_handle, status);

    int rc = os_mbuf_append(ctxt->om, status, length);

    return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}

/* 手机写入002 -> 日志 -> 转换 -> UART队列。 */
static int rx_access(uint16_t conn_handle,
                     uint16_t attr_handle,
                     struct ble_gatt_access_ctxt *ctxt,
                     void *arg)
{
    (void)arg;

    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        return read_status(attr_handle, ctxt);
    }

    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }

    unsigned long count;

    portENTER_CRITICAL(&state_lock);
    count = ++ble_rx_count;
    portEXIT_CRITICAL(&state_lock);

    ESP_LOGI(TAG,
             "WRITE ENTER: conn=%u handle=0x%04X "
             "expected=0x%04X count=%lu",
             (unsigned)conn_handle,
             (unsigned)attr_handle,
             (unsigned)rx_value_handle,
             count);

    uint16_t length = OS_MBUF_PKTLEN(ctxt->om);

    if (length == 0 || length > WRITE_MAX) {
        ESP_LOGW(TAG, "Invalid write length: %u",
                 (unsigned)length);
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }

    uart_packet_t packet = {0};
    packet.length = length;

    if (os_mbuf_copydata(
            ctxt->om, 0, length, packet.data) != 0) {
        ESP_LOGE(TAG, "Copy BLE data failed");
        return BLE_ATT_ERR_UNLIKELY;
    }

    ESP_LOGI(TAG, "BLE RX: %u bytes", (unsigned)length);
    ESP_LOG_BUFFER_HEX_LEVEL(
        TAG, packet.data, packet.length, ESP_LOG_INFO);

    if (!normalize_packet(&packet)) {
        ESP_LOGW(TAG,
                 "Invalid HEX text; example: A5 90 3C 64 6D");
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }

    if (write_queue == NULL ||
        xQueueSend(write_queue, &packet, 0) != pdTRUE) {
        ESP_LOGE(TAG, "UART queue full or unavailable");
        return BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    return 0;
}

/* 003仅用于读取状态和通知，不接受写入。 */
static int tx_access(uint16_t conn_handle,
                     uint16_t attr_handle,
                     struct ble_gatt_access_ctxt *ctxt,
                     void *arg)
{
    (void)conn_handle;
    (void)arg;

    if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) {
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }

    return read_status(attr_handle, ctxt);
}

static const struct ble_gatt_chr_def characteristics[] = {
    {
        .uuid = &rx_uuid.u,
        .access_cb = rx_access,
        .flags = BLE_GATT_CHR_F_READ |
                 BLE_GATT_CHR_F_WRITE |
                 BLE_GATT_CHR_F_WRITE_NO_RSP,
        .val_handle = &rx_value_handle,
    },
    {
        .uuid = &tx_uuid.u,
        .access_cb = tx_access,
        .flags = BLE_GATT_CHR_F_READ |
                 BLE_GATT_CHR_F_NOTIFY,
        .val_handle = &tx_value_handle,
    },
    {0}
};

static const struct ble_gatt_svc_def services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &service_uuid.u,
        .characteristics = characteristics,
    },
    {0}
};

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;

    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            set_link_state(event->connect.conn_handle, false);

            ESP_LOGI(TAG, "Phone connected: conn=%u",
                     (unsigned)event->connect.conn_handle);

            ESP_LOGI(TAG,
                     "002 handle=0x%04X; 003 handle=0x%04X",
                     (unsigned)rx_value_handle,
                     (unsigned)tx_value_handle);
        } else {
            ESP_LOGW(TAG, "Connection failed: status=%d",
                     event->connect.status);
            advertise();
        }
        break;

    case BLE_GAP_EVENT_DISCONNECT:
        set_link_state(BLE_HS_CONN_HANDLE_NONE, false);

        ESP_LOGI(TAG, "Disconnected: reason=%d",
                 event->disconnect.reason);

        advertise();
        break;

    case BLE_GAP_EVENT_SUBSCRIBE:
        ESP_LOGI(TAG,
                 "SUBSCRIBE handle=0x%04X notify=%u",
                 (unsigned)event->subscribe.attr_handle,
                 (unsigned)event->subscribe.cur_notify);

        if (event->subscribe.attr_handle == tx_value_handle) {
            bool subscribed = event->subscribe.cur_notify != 0;

            set_link_state(
                event->subscribe.conn_handle, subscribed);

            ESP_LOGI(TAG, "TX notifications: %s",
                     subscribed ? "ON" : "OFF");
        }
        break;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        advertise();
        break;

    default:
        break;
    }

    return 0;
}

static void advertise(void)
{
    if (ble_gap_adv_active()) {
        return;
    }

    struct ble_hs_adv_fields fields = {0};

    fields.flags =
        BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;

    fields.uuids128 = (ble_uuid128_t *)&service_uuid;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv_set_fields failed: %d", rc);
        return;
    }

    struct ble_hs_adv_fields scan_response = {0};

    scan_response.name = (const uint8_t *)DEVICE_NAME;
    scan_response.name_len = strlen(DEVICE_NAME);
    scan_response.name_is_complete = 1;

    rc = ble_gap_adv_rsp_set_fields(&scan_response);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv_rsp_set_fields failed: %d", rc);
        return;
    }

    struct ble_gap_adv_params params = {0};

    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;

    rc = ble_gap_adv_start(
        own_addr_type,
        NULL,
        BLE_HS_FOREVER,
        &params,
        gap_event,
        NULL);

    if (rc != 0) {
        ESP_LOGE(TAG, "adv_start failed: %d", rc);
        return;
    }

    ESP_LOGI(TAG, "Advertising: %s", DEVICE_NAME);
}

/*
 * 排查版本：每次启动生成新的随机静态地址，
 * 避免复用手机之前缓存的服务句柄。
 *
 * 同一次启动期间，断线重连或host reset保留该地址。
 */
static void on_sync(void)
{
    static bool address_ready;
    static ble_addr_t address;

    int rc;

    if (!address_ready) {
        rc = ble_hs_id_gen_rnd(0, &address);
        if (rc != 0) {
            ESP_LOGE(TAG, "Generate address failed: %d", rc);
            return;
        }

        address_ready = true;
    }

    rc = ble_hs_id_set_rnd(address.val);
    if (rc != 0) {
        ESP_LOGE(TAG, "Set address failed: %d", rc);
        return;
    }

    own_addr_type = BLE_OWN_ADDR_RANDOM;

    ESP_LOGI(TAG,
             "FIX3 address=%02X:%02X:%02X:%02X:%02X:%02X",
             address.val[5], address.val[4],
             address.val[3], address.val[2],
             address.val[1], address.val[0]);

    ESP_LOGI(TAG,
             "GATT handles: 002=0x%04X 003=0x%04X",
             (unsigned)rx_value_handle,
             (unsigned)tx_value_handle);

    advertise();
}

static void on_reset(int reason)
{
    set_link_state(BLE_HS_CONN_HANDLE_NONE, false);
    ESP_LOGW(TAG, "BLE host reset: reason=%d", reason);
}

static void host_task(void *arg)
{
    (void)arg;

    nimble_port_run();
    nimble_port_freertos_deinit();
}

/* 已转换的字节 -> FPGA UART。 */
static void uart_write_task(void *arg)
{
    (void)arg;
    uart_packet_t packet;

    for (;;) {
        if (xQueueReceive(
                write_queue, &packet, portMAX_DELAY) != pdTRUE) {
            continue;
        }

        ESP_LOGI(TAG, "UART TX: %u bytes",
                 (unsigned)packet.length);

        ESP_LOG_BUFFER_HEX_LEVEL(
            TAG, packet.data, packet.length, ESP_LOG_INFO);

        int written = uart_write_bytes(
            FPGA_UART, packet.data, packet.length);

        esp_err_t done = ESP_FAIL;

        if (written == packet.length) {
            done = uart_wait_tx_done(
                FPGA_UART, pdMS_TO_TICKS(200));
        }

        portENTER_CRITICAL(&state_lock);
        uart_tx_length = written > 0 ? (unsigned)written : 0;
        portEXIT_CRITICAL(&state_lock);

        bool ok =
            written == packet.length && done == ESP_OK;

        char reply[21];

        int length = snprintf(
            reply, sizeof(reply),
            ok ? "UART OK %u" : "UART FAIL %u",
            (unsigned)packet.length);

        if (ok) {
            ESP_LOGI(TAG, "%s", reply);
        } else {
            ESP_LOGE(TAG,
                     "UART failed: requested=%u written=%d wait=%s",
                     (unsigned)packet.length,
                     written,
                     esp_err_to_name(done));
        }

        if (length > 0 && length < (int)sizeof(reply)) {
            notify_phone(reply, (uint16_t)length);
        }
    }
}

/*
 * FPGA UART返回数据 -> 手机003通知。
 * 即使FPGA没有返回数据，上面的UART任务仍会发送确认消息。
 */
static void uart_read_task(void *arg)
{
    (void)arg;
    uint8_t data[NOTIFY_BYTES];

    for (;;) {
        int length = uart_read_bytes(
            FPGA_UART,
            data,
            sizeof(data),
            pdMS_TO_TICKS(20));

        if (length <= 0) {
            continue;
        }

        ESP_LOGI(TAG, "UART RX: %d bytes", length);

        ESP_LOG_BUFFER_HEX_LEVEL(
            TAG, data, length, ESP_LOG_INFO);

        notify_phone(data, (uint16_t)length);
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "Starting FIX3; built %s %s",
             __DATE__, __TIME__);

    esp_err_t err = nvs_flash_init();

    if (err == ESP_ERR_NVS_NO_FREE_PAGES ||
        err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }

    ESP_ERROR_CHECK(err);

    write_queue = xQueueCreate(
        WRITE_QUEUE_LEN, sizeof(uart_packet_t));

    if (write_queue == NULL) {
        ESP_LOGE(TAG, "Create UART queue failed");
        abort();
    }

    uart_config_t config = {
        .baud_rate = FPGA_BAUD,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };

    ESP_ERROR_CHECK(uart_param_config(FPGA_UART, &config));

    ESP_ERROR_CHECK(uart_set_pin(
        FPGA_UART,
        FPGA_TX_PIN,
        FPGA_RX_PIN,
        UART_PIN_NO_CHANGE,
        UART_PIN_NO_CHANGE));

    ESP_ERROR_CHECK(uart_driver_install(
        FPGA_UART,
        4096,
        2048,
        0,
        NULL,
        0));

    ESP_ERROR_CHECK(nimble_port_init());

    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb = on_sync;

    ble_svc_gap_init();
    ble_svc_gatt_init();

    check_ble(
        ble_svc_gap_device_name_set(DEVICE_NAME),
        "Set device name");

    check_ble(
        ble_gatts_count_cfg(services),
        "Count GATT services");

    check_ble(
        ble_gatts_add_svcs(services),
        "Add GATT services");

    if (xTaskCreate(
            uart_write_task,
            "fpga_uart_tx",
            4096,
            NULL,
            5,
            NULL) != pdPASS) {
        ESP_LOGE(TAG, "Create UART TX task failed");
        abort();
    }

    if (xTaskCreate(
            uart_read_task,
            "fpga_uart_rx",
            4096,
            NULL,
            5,
            NULL) != pdPASS) {
        ESP_LOGE(TAG, "Create UART RX task failed");
        abort();
    }

    ESP_LOGI(TAG,
             "FIX3 ready: UART RX=%d TX=%d baud=%d",
             FPGA_RX_PIN, FPGA_TX_PIN, FPGA_BAUD);

    nimble_port_freertos_init(host_task);
}