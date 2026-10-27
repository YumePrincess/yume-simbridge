export async function wakeEdge(env: Env) {
  try {
    await env.WAKE_HUB.getByName("module").wake();
  } catch {
    console.warn(JSON.stringify({ event: "edge.wake.deferred" }));
  }
}
