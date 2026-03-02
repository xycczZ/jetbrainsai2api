package server

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"jetbrainsai2api/internal/core"
	"jetbrainsai2api/internal/metrics"

	"github.com/gin-gonic/gin"
)

// TestHandleAnthropicStreaming_ShouldEmitMessageDelta 验证流式响应中必须包含 message_delta 事件。
// Claude 客户端强依赖此事件来确认响应完整性，缺失将导致 ECONNRESET。
func TestHandleAnthropicStreaming_ShouldEmitMessageDelta(t *testing.T) {
	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPost, "/v1/messages", nil)

	// 模拟普通文本响应流（stop reason = end_turn）
	streamBody := strings.Join([]string{
		`data: {"type":"Content","content":"Hello, world!"}`,
		`data: {"type":"FinishMetadata","reason":"stop"}`,
		`data: end`,
		"",
	}, "\n")

	resp := &http.Response{Body: io.NopCloser(strings.NewReader(streamBody))}
	m := metrics.NewMetricsService(metrics.MetricsConfig{SaveInterval: time.Second, HistorySize: 10, Storage: nil, Logger: &core.NopLogger{}})
	defer func() { _ = m.Close() }()

	handleAnthropicStreamingResponseWithMetrics(c, resp, &core.AnthropicMessagesRequest{Model: "claude-3-5-sonnet-20241022"}, time.Now(), "acc", m, &core.NopLogger{})

	body := w.Body.String()

	// 验证 message_delta 事件存在
	if !strings.Contains(body, "event: message_delta") {
		t.Fatalf("流式响应应包含 message_delta 事件，实际输出: %s", body)
	}

	// 验证 stop_reason 为 end_turn
	if !strings.Contains(body, `"stop_reason":"end_turn"`) {
		t.Fatalf("message_delta 应包含 stop_reason=end_turn，实际输出: %s", body)
	}

	// 验证事件顺序：message_delta 必须在 message_stop 之前
	messageDeltaPos := strings.Index(body, "event: message_delta")
	messageStopPos := strings.Index(body, "event: message_stop")
	if messageDeltaPos == -1 || messageStopPos == -1 {
		t.Fatalf("缺少 message_delta 或 message_stop 事件，实际输出: %s", body)
	}
	if messageDeltaPos >= messageStopPos {
		t.Fatalf("message_delta 应在 message_stop 之前发送，实际顺序错误")
	}
}

// TestHandleAnthropicStreaming_ToolCallShouldEmitToolUseStopReason 验证 Tool Call 场景下 stop_reason 为 tool_use。
func TestHandleAnthropicStreaming_ToolCallShouldEmitToolUseStopReason(t *testing.T) {
	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPost, "/v1/messages", nil)

	// 模拟 Tool Call 响应流（stop reason = tool_call）
	streamBody := strings.Join([]string{
		`data: {"type":"ToolCall","id":"toolu_test","name":"get_weather"}`,
		`data: {"type":"ToolCall","content":"{\"city\":\"Beijing\"}"}`,
		`data: {"type":"FinishMetadata","reason":"tool_call"}`,
		`data: end`,
		"",
	}, "\n")

	resp := &http.Response{Body: io.NopCloser(strings.NewReader(streamBody))}
	m := metrics.NewMetricsService(metrics.MetricsConfig{SaveInterval: time.Second, HistorySize: 10, Storage: nil, Logger: &core.NopLogger{}})
	defer func() { _ = m.Close() }()

	handleAnthropicStreamingResponseWithMetrics(c, resp, &core.AnthropicMessagesRequest{Model: "claude-3-5-sonnet-20241022"}, time.Now(), "acc", m, &core.NopLogger{})

	body := w.Body.String()

	// 验证 message_delta 中 stop_reason 为 tool_use
	if !strings.Contains(body, `"stop_reason":"tool_use"`) {
		t.Fatalf("Tool Call 场景下 message_delta 应包含 stop_reason=tool_use，实际输出: %s", body)
	}
}
