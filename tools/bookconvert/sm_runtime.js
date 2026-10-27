/* Contained AXMA JS compatibility session, MIT. No browser or OS bridge.
 * Public API semantics: https://axmajs.ru/ru/manual/ . Independent code only.
 * Used only by the contained reader worker, never copied into route exports. */
(function (global) {
    var passages = Object.create(null), actions = Object.create(null);
    var parts = [], current = "", previous = "", picturePath = "";
    var nextId = 0, generation = 0, count = 0, started = false, inputValue = "";
    var menuValue = "", titleValue = "", visitedCounts = Object.create(null);
    var regions = {title: null, menu: null};
    var MAX_PARTS = 100000, MAX_TEXT = 4 * 1024 * 1024;
    var inlineActions = Object.create(null), inlineCount = 0;
    var outputSize = 0, markerStart = "\u001eMHL-SM:", markerEnd = "\u001f";
    var clockValue = 0;

    function fail(message) { throw new Error(message); }
    function add(part) {
        var value = String(part.text || part.label || "");
        outputSize += value.length;
        if (parts.length >= MAX_PARTS || outputSize > MAX_TEXT)
            fail("Слишком большой вывод интерактивной книги.");
        parts.push(part);
    }
    function register(label, target, kind, callback, input) {
        if (typeof target !== "string" && typeof target !== "function")
            fail("Неверный переход интерактивной книги.");
        if (kind !== "" && kind !== "+" && kind !== "*") fail("Неизвестный тип перехода.");
        if (callback !== null && callback !== undefined && typeof callback !== "function")
            fail("Неверное действие ссылки.");
        if (++count > MAX_PARTS) fail("Слишком много действий интерактивной книги.");
        var id = ++nextId;
        actions[id] = {target: target, kind: kind, callback: callback, input: input,
                       generation: generation};
        return {kind: input ? "input" : "link", id: id, label: String(label),
                target: typeof target === "string" ? target : "", mode: kind};
    }
    function link(label, target, kind, callback) {
        if (typeof target === "function" || target === undefined) {
            callback = target || null; target = "";
        }
        var part = register(label, target, kind || "", callback || null, false);
        // A marker lets normal JS string concatenation retain link semantics.
        actions[part.id].part = part;
        return markerStart + part.id + markerEnd;
    }
    function splitOutput(value) {
        value = String(value);
        if (value.length > MAX_TEXT) fail("Слишком большой вывод интерактивной книги.");
        var result = [], start = 0, at, close, id, action;
        while ((at = value.indexOf(markerStart, start)) >= 0) {
            close = value.indexOf(markerEnd, at + markerStart.length);
            if (close < 0) break;
            id = value.slice(at + markerStart.length, close);
            action = /^\d+$/.test(id) ? actions[id] : null;
            if (!action || action.generation !== generation || !action.part)
                fail("Устаревшая ссылка в тексте интерактивной книги.");
            if (at > start) result.push({kind: "text", text: value.slice(start, at)});
            result.push(action.part); start = close + markerEnd.length;
            if (result.length > MAX_PARTS) fail("Слишком большой вывод интерактивной книги.");
        }
        if (start < value.length || value.length === 0)
            result.push({kind: "text", text: value.slice(start)});
        return result;
    }
    function print(value) {
        var result = splitOutput(value);
        for (var i = 0; i < result.length; i++) add(result[i]);
    }
    function holdRegion(name, output) {
        var references = Object.create(null);
        for (var i = 0; i < output.length; i++) {
            if (output[i].kind === "link" || output[i].kind === "input") {
                references[output[i].id] = actions[output[i].id];
                references[output[i].id].part = output[i];
            }
        }
        regions[name] = {parts: output, actions: references};
    }
    function setRegion(name, value) {
        value = String(value);
        if (value.length > 65536) fail("Слишком большой заголовок или меню интерактивной книги.");
        holdRegion(name, value ? splitOutput(value) : []);
        return value;
    }
    function restoreRegions() {
        // Menu/title links belong to persistent areas, not to a departed
        // passage. Preserve their closures, but no stale passage-only action.
        for (var name in regions) {
            var region = regions[name];
            if (!region) continue;
            for (var id in region.actions) {
                if (!Object.prototype.hasOwnProperty.call(actions, id)) {
                    if (++count > MAX_PARTS) fail("Слишком много действий интерактивной книги.");
                    actions[id] = region.actions[id];
                }
                actions[id].generation = generation;
            }
        }
    }
    function line(values) {
        for (var i = 0; i < values.length; i++) print(values[i]);
        add({kind: "newline"});
    }
    function reset() { parts = []; outputSize = 0; }
    function initializeMenu() {
        // The optional StoryMenu runs once before Start, into its own area.
        // It is initialization, not a visited story passage. Keep its actions
        // and lexical closures alive when Start creates the first generation.
        if (!Object.prototype.hasOwnProperty.call(passages, "StoryMenu")) return;
        passages.StoryMenu();
        if (parts.length) {
            var value = "";
            for (var i = 0; i < parts.length; i++) {
                var part = parts[i];
                if (part.kind === "text") value += part.text;
                else if (part.kind === "newline") value += "\n";
                else if (part.kind === "link" || part.kind === "input")
                    value += markerStart + part.id + markerEnd;
                if (value.length > 65536)
                    fail("Слишком большой заголовок или меню интерактивной книги.");
            }
            menuValue = value; holdRegion("menu", parts);
        }
        // An empty/comment-only StoryMenu leaves the historical frame shape
        // unchanged, including journals saved before this support was added.
        reset();
    }
    function enter(name, mode) {
        if (!Object.prototype.hasOwnProperty.call(passages, name))
            fail("В книге отсутствует параграф: " + name);
        if (!mode) {
            generation++; count = 0; actions = Object.create(null); restoreRegions();
        }
        previous = current; current = name;
        visitedCounts[name] = (visitedCounts[name] || 0) + 1;
        passages[name]();
    }
    function frame(mode) {
        restoreRegions();
        var result = {parts: parts, passage: current, from: previous,
            picture: picturePath, title: titleValue, menu: menuValue, mode: mode || "",
            generation: generation}, output = {}, any = false;
        for (var name in regions) {
            if (regions[name] && regions[name].parts.length) {
                output[name] = regions[name].parts; any = true;
            }
        }
        // Empty regions leave historical frames unchanged, so existing
        // journals of stories which never use them still replay exactly.
        if (any) result.regions = output;
        return JSON.stringify(result);
    }
    function random(min, max) {
        if (max === undefined) { max = min; min = 0; }
        if (typeof min !== "number" || typeof max !== "number" ||
            !isFinite(min) || !isFinite(max) || Math.floor(min) !== min ||
            Math.floor(max) !== max || max < min || max - min > 0x1fffffffffffff)
            fail("Неверные границы случайного числа.");
        return Math.floor(Math.random() * (max - min + 1)) + min;
    }
    var api = {
        configure: function (seed, clock) {
            if (started || typeof seed !== "number" || seed !== (seed >>> 0) ||
                    typeof clock !== "number" || !isFinite(clock) || clock < 0)
                fail("Неверные параметры сохранённой истории.");
            var state = seed >>> 0;
            Math.random = function () {
                state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
                return state / 4294967296;
            };
            clockValue = clock;
            Date.now = function () { return clockValue; };
        },
        setClock: function (clock) {
            if (typeof clock !== "number" || !isFinite(clock) || clock < 0)
                fail("Неверное время сохранённой истории.");
            clockValue = clock;
        },
        defineInline: function (callback) {
            if (started || typeof callback !== "function" || inlineCount >= MAX_PARTS)
                fail("Неверное действие ссылки.");
            inlineActions[++inlineCount] = callback;
            return inlineCount;
        },
        inline: function (id) {
            if (!Object.prototype.hasOwnProperty.call(inlineActions, id))
                fail("Действие ссылки отсутствует.");
            return inlineActions[id];
        },
        define: function (name, callback) {
            if (started || typeof callback !== "function" ||
                Object.prototype.hasOwnProperty.call(passages, name)) fail("Повторный параграф.");
            passages[name] = callback;
        },
        line: line, link: link,
        start: function () {
            if (started) fail("История уже запущена.");
            started = true; reset(); initializeMenu(); enter("Start", ""); return frame("");
        },
        choose: function (id, text) {
            if (!started) fail("История ещё не запущена.");
            var action = actions[id];
            if (!action || action.generation !== generation) fail("Устаревший переход.");
            // Consume before executing: even an append/input action is single use.
            delete actions[id]; reset();
            if (action.input) {
                if (typeof text !== "string" || text.length > 65536) fail("Неверный ввод.");
                inputValue = text;
            }
            if (action.callback) action.callback();
            if (typeof action.target === "function") action.target(inputValue);
            else if (/^https?:\/\//i.test(action.target))
                add({kind: "external", target: action.target});
            else if (action.target) enter(action.target, action.kind);
            return frame(action.kind);
        }
    };
    Object.defineProperty(global, "__mhlSm", {value: api});
    global.window = global; // Language global only: no DOM, file, COM or network.
    global.asm = {save: true};
    global.print = print;
    global.link = link;
    global.button = link;
    global.random = random;
    global.input = function (target) { add(register("", target, "", null, true)); };
    global.picture = function (path) {
        if (arguments.length && typeof path !== "string") fail("Неверное имя иллюстрации.");
        picturePath = arguments.length ? path : "";
    };
    global.menu = function (value) {
        if (arguments.length) menuValue = setRegion("menu", value);
        return menuValue;
    };
    global.title = function (value) {
        if (arguments.length) titleValue = setRegion("title", value);
        return titleValue;
    };
    global.visited = function () {
        var result = Infinity;
        for (var i = 0; i < arguments.length; i++) result = Math.min(result, visitedCounts[arguments[i]] || 0);
        return arguments.length ? result : (visitedCounts[current] || 0);
    };
    Object.defineProperty(global, "$$title", {get: function () { return current; }});
    Object.defineProperty(global, "$$from", {get: function () { return previous; }});
    Object.defineProperty(global, "$$input", {get: function () { return inputValue; }});
    Object.defineProperty(global, "$$time", {get: function () { return Math.floor(Date.now() / 1000); }});
})(this);
