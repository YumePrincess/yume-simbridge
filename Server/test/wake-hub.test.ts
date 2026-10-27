import { it, expect, vi } from "vitest";
import { WakeHub } from "../src/wake-hub";
it("uses hibernation-safe socket enumeration and automatic ping/pong", async () => {
  vi.stubGlobal(
    "WebSocketRequestResponsePair",
    class {
      constructor(
        public request: string,
        public response: string,
      ) {}
    },
  );
  const first = { send: vi.fn(), close: vi.fn() },
    stale = {
      send: vi.fn(() => {
        throw Error("closed");
      }),
      close: vi.fn(),
    };
  const ctx = {
    setWebSocketAutoResponse: vi.fn(),
    getWebSockets: () => [first, stale],
  };
  const hub = new WakeHub(ctx as unknown as DurableObjectState, {} as Env);
  expect(ctx.setWebSocketAutoResponse).toHaveBeenCalledOnce();
  await hub.wake();
  expect(first.send).toHaveBeenCalledWith("wake");
  expect(stale.close).toHaveBeenCalled();
  expect(
    (await hub.fetch(new Request("https://internal/connect"))).status,
  ).toBe(426);
  vi.unstubAllGlobals();
});
