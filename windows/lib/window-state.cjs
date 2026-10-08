"use strict";
class WindowState {
  constructor() {
    this.windows = new Map();
    this.bindings = new Map();
  }
  add(id, epoch = 1) {
    const state = {
      id,
      epoch,
      current: null,
      held: new Set(),
      page: null,
      sequence: 0,
    };
    this.windows.set(id, state);
    return state;
  }
  owner(id) {
    const s = this.windows.get(id);
    if (!s) throw new Error("窗口已关闭");
    return { id, epoch: s.epoch };
  }
  assert(owner) {
    const s = this.windows.get(owner.id);
    if (!s || s.epoch !== owner.epoch) throw new Error("页面已失效");
    return s;
  }
  holder(draftId, except) {
    return [...this.windows.values()].find(
      (s) => s.id !== except && s.held.has(draftId),
    );
  }
  occupy(owner, request) {
    const s = this.assert(owner);
    if (
      typeof request.page !== "string" ||
      !Number.isSafeInteger(request.sequence) ||
      request.sequence < 1
    )
      throw new Error("窗口报告不合规");
    if (s.page && s.page !== request.page) return { ignored: true };
    if (request.sequence <= s.sequence) return { ignored: true };
    const held = new Set(
      (request.drafts || []).filter((id) => typeof id === "string"),
    );
    for (const id of held)
      if (this.holder(id, s.id)) throw new Error("稿件已在其他窗口打开");
    s.page = request.page;
    s.sequence = request.sequence;
    s.current = request.current;
    s.held = held;
    return {};
  }
  reload(id) {
    const previous = this.owner(id);
    this.add(id, previous.epoch + 1);
    return previous;
  }
  remove(id) {
    this.windows.delete(id);
  }
  bind(session, draftId) {
    if (
      typeof session !== "string" ||
      !session ||
      session.length > 200 ||
      typeof draftId !== "string" ||
      !draftId
    )
      throw new Error("会话绑定不合规");
    this.bindings.set(session, draftId);
  }
}
module.exports = { WindowState };
