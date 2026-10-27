import { DurableObject } from "cloudflare:workers";

// Carries no message content, numbers or credentials. D1 remains the durable
// queue; reconnect always wakes the client to claim any outstanding work.
export class WakeHub extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair("ping", "pong"),
    );
  }
  async fetch(req: Request) {
    if (req.headers.get("Upgrade")?.toLowerCase() !== "websocket")
      return new Response("WebSocket required", { status: 426 });
    if (this.ctx.getWebSockets().length >= 4)
      return new Response("Too many clients", { status: 429 });
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    pair[1].send("wake");
    return new Response(null, { status: 101, webSocket: pair[0] });
  }
  async wake() {
    for (const socket of this.ctx.getWebSockets()) {
      try {
        socket.send("wake");
      } catch {
        socket.close(1011, "Reconnect");
      }
    }
  }
  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer) {
    // ping is answered by the runtime without waking this object.
    if (message !== "ping") socket.close(1008, "Unexpected message");
  }
  async webSocketClose(socket: WebSocket, code: number) {
    socket.close(code);
  }
  async webSocketError(socket: WebSocket) {
    socket.close(1011, "Reconnect");
  }
}
