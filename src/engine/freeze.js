// 深冻结：对象、数组连同里面的对象、数组一起 Object.freeze（函数不动）。注册表、配色库、App API 等常量共用这一份。
(function (root) {
  "use strict";

  function deepFreeze(value) {
    if (value && typeof value === "object") {
      Object.values(value).forEach(deepFreeze);
      Object.freeze(value);
    }
    return value;
  }

  const engine = root.MediaCraftEngine || (root.MediaCraftEngine = {});
  engine.deepFreeze = deepFreeze;
})(globalThis);
