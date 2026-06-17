import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

PanelWindow {
    id: sidebar

    property int panelWidth: 380
    property bool isVisible: false
    // Leave room at the top so the floating panel never rides over the waybar.
    property int topMargin: 44
    property string apiBase: "http://127.0.0.1:8000"
    property string activeTab: "chat"

    // Full-screen overlay so we can (a) show an edge handle when closed and
    // (b) catch clicks outside the panel to dismiss it. Input is restricted to
    // the visible bits via `mask`, so the rest of the screen stays clickable.
    anchors { left: true; right: true; top: true; bottom: true }
    exclusionMode: ExclusionMode.Ignore
    visible: true
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: isVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    // Only the handle is interactive when closed; the whole scrim when open.
    mask: Region { item: sidebar.isVisible ? scrim : handle }

    // --- runtime state ---
    property var activeXhr: null
    property int streamingIdx: -1
    property bool serverRunning: false
    property bool serverHealthy: false
    property string serverModel: ""
    property string lastTokS: ""

    // --- editable pending config (mirrors backend gideon_config.json) ---
    property string cfgModelPath: ""
    property bool   cfgModelIsMoe: false
    property int    cfgModelLayers: 46
    property int    cfgCtx: 8192
    property string cfgKvK: "q8_0"
    property string cfgKvV: "turbo4"
    property int    cfgNCpuMoe: 38
    property int    cfgNgl: 99
    property bool   cfgFlashAttn: true
    property bool   cfgMlock: false
    property bool   cfgNoMmap: false

    property var availableModels: []
    property string cfgModelsDir: ""
    property string modelsDirStatus: ""
    property bool settingsLoaded: false

    // --- estimate + live usage (MB) ---
    property int estVram: 0
    property int estVramTotal: 6141
    property int estRam: 0
    property int estRamTotal: 15701
    property bool estVramOom: false
    property bool estRamOom: false
    property int liveVramUsed: 0
    property int liveVramTotal: 6141
    property int liveRamUsed: 0
    property int liveRamTotal: 15701
    property string applyStatus: ""
    property bool applying: false

    function toggle() { isVisible = !isVisible; if (isVisible) refreshServerStatus(); }

    // IPC: bind a Hyprland key to `qs ipc call gideon toggle`.
    IpcHandler {
        target: "gideon"
        function toggle(): void { sidebar.toggle(); }
        function show(): void { sidebar.isVisible = true; sidebar.refreshServerStatus(); }
        function hide(): void { sidebar.isVisible = false; }
    }

    function openFile(path) {
        var x = new XMLHttpRequest();
        x.open("POST", sidebar.apiBase + "/api/open");
        x.setRequestHeader("Content-Type", "application/json");
        x.send(JSON.stringify({"prompt": path}));
    }

    function copyText(t) { Quickshell.clipboardText = t; }

    // ----- settings / server networking -----
    function currentConfig() {
        return {
            "model_path": sidebar.cfgModelPath,
            "ctx": sidebar.cfgCtx,
            "kv_k": sidebar.cfgKvK,
            "kv_v": sidebar.cfgKvV,
            "n_cpu_moe": sidebar.cfgNCpuMoe,
            "ngl": sidebar.cfgNgl,
            "flash_attn": sidebar.cfgFlashAttn,
            "mlock": sidebar.cfgMlock,
            "no_mmap": sidebar.cfgNoMmap
        };
    }

    function applyModelMeta(path) {
        for (var i = 0; i < sidebar.availableModels.length; i++) {
            if (sidebar.availableModels[i].path === path) {
                sidebar.cfgModelIsMoe = sidebar.availableModels[i].moe;
                sidebar.cfgModelLayers = sidebar.availableModels[i].layers;
                return;
            }
        }
    }

    function refreshModels() {
        var x = new XMLHttpRequest();
        x.onreadystatechange = function() {
            if (x.readyState !== XMLHttpRequest.DONE || x.status !== 200) return;
            var d = JSON.parse(x.responseText);
            sidebar.availableModels = d.models || [];
            if (d.models_dir) sidebar.cfgModelsDir = d.models_dir;
            if (!sidebar.settingsLoaded && d.current) {
                var c = d.current;
                sidebar.cfgModelPath = c.model_path || "";
                sidebar.cfgCtx = c.ctx || 8192;
                sidebar.cfgKvK = c.kv_k || "q8_0";
                sidebar.cfgKvV = c.kv_v || "turbo4";
                sidebar.cfgNCpuMoe = c.n_cpu_moe || 38;
                sidebar.cfgNgl = c.ngl || 99;
                sidebar.cfgFlashAttn = c.flash_attn !== false;
                sidebar.cfgMlock = c.mlock === true;
                sidebar.cfgNoMmap = c.no_mmap === true;
                sidebar.applyModelMeta(sidebar.cfgModelPath);
                sidebar.settingsLoaded = true;
            }
            sidebar.requestEstimate();
        }
        x.open("GET", sidebar.apiBase + "/api/models");
        x.send();
    }

    function setModelsDir(path) {
        sidebar.modelsDirStatus = "Scanning…";
        var x = new XMLHttpRequest();
        x.onreadystatechange = function() {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            try {
                var d = JSON.parse(x.responseText);
                if (d.ok) {
                    sidebar.availableModels = d.models || [];
                    sidebar.cfgModelsDir = d.models_dir;
                    sidebar.modelsDirStatus = "✓ " + (d.models.length) + " model(s) found";
                } else {
                    sidebar.modelsDirStatus = "⚠ " + (d.error || "Failed.");
                }
            } catch (e) { sidebar.modelsDirStatus = "⚠ Backend unreachable."; }
        }
        x.open("POST", sidebar.apiBase + "/api/models_dir");
        x.setRequestHeader("Content-Type", "application/json");
        x.send(JSON.stringify({"path": path}));
    }

    function refreshSystem() {
        var x = new XMLHttpRequest();
        x.onreadystatechange = function() {
            if (x.readyState !== XMLHttpRequest.DONE || x.status !== 200) return;
            var d = JSON.parse(x.responseText);
            sidebar.liveVramUsed = d.vram_used_mb;
            sidebar.liveVramTotal = d.vram_total_mb || 6141;
            sidebar.liveRamUsed = d.ram_used_mb;
            sidebar.liveRamTotal = d.ram_total_mb || 15701;
        }
        x.open("GET", sidebar.apiBase + "/api/system/info");
        x.send();
    }

    function refreshServerStatus() {
        var x = new XMLHttpRequest();
        x.onreadystatechange = function() {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            if (x.status !== 200) { sidebar.serverHealthy = false; sidebar.serverRunning = false; return; }
            var d = JSON.parse(x.responseText);
            sidebar.serverRunning = d.running;
            sidebar.serverHealthy = d.healthy;
            sidebar.serverModel = d.model || "";
        }
        x.open("GET", sidebar.apiBase + "/api/server/status");
        x.send();
    }

    function setServer(on) {
        sidebar.applying = true;
        sidebar.applyStatus = on ? "Starting llama-server… (model load can take ~30s)"
                                 : "Stopping llama-server…";
        var x = new XMLHttpRequest();
        x.onreadystatechange = function() {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            sidebar.applying = false;
            try {
                var d = JSON.parse(x.responseText);
                sidebar.applyStatus = (d.ok ? "✓ " : "⚠ ") + (d.message || d.error || "");
            } catch (e) { sidebar.applyStatus = "⚠ Backend unreachable."; }
            sidebar.refreshServerStatus();
            sidebar.refreshSystem();
        }
        if (on) {
            x.open("POST", sidebar.apiBase + "/api/server/start");
            x.setRequestHeader("Content-Type", "application/json");
            x.send(JSON.stringify({"config": sidebar.currentConfig()}));
        } else {
            x.open("POST", sidebar.apiBase + "/api/server/stop");
            x.send();
        }
    }

    function requestEstimate() {
        if (sidebar.cfgModelPath === "") return;
        var x = new XMLHttpRequest();
        x.onreadystatechange = function() {
            if (x.readyState !== XMLHttpRequest.DONE || x.status !== 200) return;
            var d = JSON.parse(x.responseText);
            sidebar.estVram = d.vram_est_mb;
            sidebar.estVramTotal = d.vram_total_mb || 6141;
            sidebar.estRam = d.ram_est_mb;
            sidebar.estRamTotal = d.ram_total_mb || 15701;
            sidebar.estVramOom = d.vram_oom;
            sidebar.estRamOom = d.ram_oom;
        }
        x.open("POST", sidebar.apiBase + "/api/estimate");
        x.setRequestHeader("Content-Type", "application/json");
        x.send(JSON.stringify({"config": sidebar.currentConfig()}));
    }

    function applyConfig() {
        sidebar.applying = true;
        sidebar.applyStatus = "Restarting llama-server… (model load can take ~30s)";
        var x = new XMLHttpRequest();
        x.onreadystatechange = function() {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            sidebar.applying = false;
            try {
                var d = JSON.parse(x.responseText);
                sidebar.applyStatus = d.ok ? "✓ " + (d.message || "Applied.")
                                           : "⚠ " + (d.error || "Failed.");
            } catch (e) { sidebar.applyStatus = "⚠ Backend unreachable."; }
            sidebar.refreshServerStatus();
            sidebar.refreshSystem();
        }
        x.open("POST", sidebar.apiBase + "/api/server/restart");
        x.setRequestHeader("Content-Type", "application/json");
        x.send(JSON.stringify({"config": sidebar.currentConfig()}));
    }

    // Run a user-confirmed command and show its output as a new chat bubble.
    function executeCommand(cmd) {
        chatModel.append({"role": "assistant", "content": "", "action": "",
                          "filesJson": "[]", "status": "⚙ running…",
                          "thinking": "", "thinkingOpen": false, "stats": ""});
        var idx = chatModel.count - 1;
        var x = new XMLHttpRequest();
        x.onreadystatechange = function() {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            chatModel.setProperty(idx, "status", "");
            try {
                var d = JSON.parse(x.responseText);
                var head = "$ " + d.command + "  (exit " + d.returncode + ")\n";
                chatModel.setProperty(idx, "content", "```\n" + head + d.output + "\n```");
            } catch (e) {
                chatModel.setProperty(idx, "content", "⚠️ Execution failed.");
            }
            chatView.positionViewAtEnd();
        }
        x.open("POST", sidebar.apiBase + "/api/execute");
        x.setRequestHeader("Content-Type", "application/json");
        x.send(JSON.stringify({"command": cmd}));
    }

    function gbStr(mb) { return (mb / 1024).toFixed(1); }

    function barColor(used, total, oom) {
        if (oom) return "#f38ba8";
        var r = total > 0 ? used / total : 0;
        if (r < 0.75) return "#a6e3a1";
        if (r < 0.92) return "#f9e2af";
        return "#fab387";
    }

    function parseSegments(md) {
        var segs = [];
        if (!md) return segs;
        var re = /```([A-Za-z0-9_+\-]*)\r?\n?([\s\S]*?)```/g;
        var last = 0, m;
        while ((m = re.exec(md)) !== null) {
            if (m.index > last) {
                var pre = md.substring(last, m.index);
                if (pre.trim() !== "") segs.push({ "type": "text", "text": pre, "lang": "" });
            }
            segs.push({ "type": "code", "text": m[2], "lang": m[1] });
            last = m.index + m[0].length;
        }
        var rest = md.substring(last);
        var open = rest.indexOf("```");
        if (open !== -1) {
            var head = rest.substring(0, open);
            if (head.trim() !== "") segs.push({ "type": "text", "text": head, "lang": "" });
            var after = rest.substring(open + 3);
            var nl = after.indexOf("\n");
            segs.push({ "type": "code",
                        "lang": nl !== -1 ? after.substring(0, nl) : "",
                        "text": nl !== -1 ? after.substring(nl + 1) : "" });
        } else if (rest.trim() !== "") {
            segs.push({ "type": "text", "text": rest, "lang": "" });
        }
        return segs;
    }

    Timer {
        id: estimateTimer
        interval: 180
        onTriggered: sidebar.requestEstimate()
    }
    Timer {
        id: systemPoll
        interval: 2000; repeat: true
        running: sidebar.activeTab === "settings" && sidebar.isVisible
        onTriggered: sidebar.refreshSystem()
    }
    Timer {
        id: statusPoll
        interval: 5000; repeat: true
        running: sidebar.isVisible
        onTriggered: sidebar.refreshServerStatus()
    }

    // Catches clicks outside the panel (only masked-in when open).
    MouseArea {
        id: scrim
        anchors.fill: parent
        onClicked: sidebar.isVisible = false
    }

    // ---------- Edge handle (left middle) ----------
    Rectangle {
        id: handle
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: handleArea.containsMouse ? 11 : 6
        height: 92
        topRightRadius: 6
        bottomRightRadius: 6
        color: "#181825"
        border.color: "#cba6f7"
        border.width: 1
        opacity: sidebar.isVisible ? 0 : 1
        Behavior on width { NumberAnimation { duration: 150 } }
        Behavior on opacity { NumberAnimation { duration: 200 } }

        // little accent grip line
        Rectangle {
            anchors.centerIn: parent
            width: 2; height: 40; radius: 1
            color: "#cba6f7"
            opacity: 0.7
        }
        MouseArea {
            id: handleArea
            anchors.fill: parent
            anchors.margins: -6   // easier to grab
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { sidebar.isVisible = true; sidebar.refreshServerStatus(); }
        }
    }

    // ---------- The panel ----------
    Rectangle {
        id: container
        property int gap: 14
        width: sidebar.panelWidth
        height: parent.height - sidebar.topMargin - gap
        y: sidebar.topMargin
        x: sidebar.isVisible ? gap : -(width + 40)
        color: "#1e1e2e"
        radius: 26
        border.color: "#313244"
        border.width: 1

        Behavior on x {
            NumberAnimation { duration: 320; easing.type: Easing.OutCubic }
        }

        // Swallow clicks on empty panel area so they don't reach the scrim.
        MouseArea { anchors.fill: parent; onClicked: {} }

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: "transparent"
            border.color: "#cba6f7"
            border.width: 1
            opacity: 0.18
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 20
            spacing: 12

            // ---------- Header ----------
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text {
                    text: "GIDEON"
                    color: "#cba6f7"; font.bold: true; font.pointSize: 18; font.letterSpacing: 2
                }
                Rectangle { height: 20; width: 2; color: "#45475a" }
                Text { text: "SYSTEM ASSISTANT"; color: "#a6adc8"; font.pointSize: 10 }
                Item { Layout.fillWidth: true }
                Text {
                    text: "✕"; color: "#f38ba8"; font.pointSize: 14
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: sidebar.isVisible = false
                    }
                }
            }

            // ---------- Tab switcher ----------
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Repeater {
                    model: [{ "id": "chat", "label": "💬  Chat" },
                            { "id": "settings", "label": "⚙  Settings" }]
                    delegate: Rectangle {
                        Layout.fillWidth: true
                        height: 34; radius: 12
                        property bool active: sidebar.activeTab === modelData.id
                        color: active ? "#313244" : "transparent"
                        border.color: active ? "#cba6f7" : "#313244"
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Text {
                            anchors.centerIn: parent
                            text: modelData.label
                            color: parent.active ? "#cba6f7" : "#a6adc8"
                            font.pointSize: 10; font.bold: parent.active
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                sidebar.activeTab = modelData.id;
                                if (modelData.id === "settings") {
                                    sidebar.refreshModels(); sidebar.refreshSystem();
                                }
                            }
                        }
                    }
                }
            }

            // ---------- Status bar ----------
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Rectangle {
                    width: 8; height: 8; radius: 4
                    color: sidebar.serverHealthy ? "#a6e3a1" : (sidebar.serverRunning ? "#f9e2af" : "#f38ba8")
                }
                Text {
                    text: sidebar.serverHealthy ? (sidebar.serverModel.split("-")[0] + " ready")
                          : sidebar.serverRunning ? "loading…" : "server off"
                    color: "#a6adc8"; font.pointSize: 8
                }
                Item { Layout.fillWidth: true }
                Text {
                    visible: sidebar.lastTokS !== ""
                    text: sidebar.lastTokS + " tok/s"
                    color: "#6c7086"; font.pointSize: 8
                }
            }

            // ---------- Content area ----------
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                // =================== CHAT ===================
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 12
                    visible: sidebar.activeTab === "chat"

                    ListModel { id: chatModel }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        color: "#11111b"; radius: 18; clip: true

                        ListView {
                            id: chatView
                            anchors.fill: parent
                            anchors.margins: 10
                            model: chatModel
                            spacing: 15

                            add: Transition {
                                NumberAnimation { property: "opacity"; from: 0; to: 1.0; duration: 400 }
                                NumberAnimation { property: "y"; from: chatView.height; duration: 400; easing.type: Easing.OutBack }
                            }

                            delegate: Column {
                                id: delegateRoot
                                width: chatView.width - 20
                                spacing: 5
                                property bool isUser: model.role === "user"
                                property bool isTerminalPrompt: model.action === "prompt_user"

                                Rectangle {
                                    width: parent.width
                                    height: contentColumn.height + 20
                                    color: isUser ? "#313244" : (isTerminalPrompt ? "#f38ba8" : "#181825")
                                    radius: 16
                                    border.color: isUser ? "#45475a" : (isTerminalPrompt ? "#eba0ac" : "#313244")
                                    border.width: 1

                                    Column {
                                        id: contentColumn
                                        width: parent.width - 24
                                        anchors.centerIn: parent
                                        spacing: 8

                                        Row {
                                            width: parent.width
                                            spacing: 10
                                            Text {
                                                text: isUser ? "YOU" : "GIDEON"
                                                color: isUser ? "#89b4fa" : "#cba6f7"
                                                font.bold: true; font.pointSize: 9
                                            }
                                            Text {
                                                id: copyIcon
                                                text: "📋"; color: "#a6adc8"; font.pointSize: 10
                                                states: State {
                                                    name: "copied"
                                                    PropertyChanges { target: copyIcon; text: "✅"; color: "#a6e3a1" }
                                                }
                                                transitions: Transition {
                                                    from: ""; to: "copied"; reversible: true
                                                    SequentialAnimation {
                                                        PauseAnimation { duration: 1000 }
                                                        PropertyAction { target: copyIcon; property: "state"; value: "" }
                                                    }
                                                }
                                                MouseArea {
                                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: { sidebar.copyText(model.content); copyIcon.state = "copied"; }
                                                }
                                            }
                                            Item { width: 4; height: 1 }
                                            Text {
                                                visible: (model.stats || "") !== ""
                                                text: model.stats || ""
                                                color: "#6c7086"; font.pointSize: 8
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }

                                        // Transient activity line.
                                        Text {
                                            width: parent.width
                                            visible: (model.status || "") !== ""
                                            text: model.status || ""
                                            color: "#f9e2af"; font.pointSize: 9; font.italic: true
                                            wrapMode: Text.Wrap
                                        }

                                        // Collapsible reasoning (GLM thinking mode).
                                        Column {
                                            width: parent.width
                                            visible: (model.thinking || "") !== ""
                                            spacing: 4
                                            Row {
                                                spacing: 6
                                                Text {
                                                    text: (model.thinkingOpen ? "▾" : "▸") + " 💭 Reasoning"
                                                    color: "#9399b2"; font.pointSize: 9; font.bold: true
                                                }
                                                MouseArea {
                                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: chatModel.setProperty(index, "thinkingOpen", !model.thinkingOpen)
                                                }
                                            }
                                            TextEdit {
                                                visible: model.thinkingOpen
                                                width: parent.width
                                                text: model.thinking || ""
                                                readOnly: true; selectByMouse: true
                                                wrapMode: TextEdit.Wrap
                                                textFormat: TextEdit.PlainText
                                                color: "#7f849c"; selectionColor: "#585b70"
                                                font.pointSize: 9; font.italic: true
                                            }
                                        }

                                        // Message body: prose + per-block copyable code cards.
                                        Column {
                                            id: bodyCol
                                            width: parent.width
                                            spacing: 8
                                            visible: (model.content || "") !== ""
                                            property var segments: sidebar.parseSegments(model.content || "")

                                            Repeater {
                                                model: bodyCol.segments
                                                delegate: Column {
                                                    width: bodyCol.width
                                                    spacing: 0

                                                    TextEdit {
                                                        visible: modelData.type === "text"
                                                        width: parent.width
                                                        text: modelData.text
                                                        readOnly: true; selectByMouse: true; persistentSelection: true
                                                        wrapMode: TextEdit.Wrap
                                                        textFormat: isUser ? TextEdit.PlainText : TextEdit.MarkdownText
                                                        color: "#cdd6f4"; selectionColor: "#585b70"; selectedTextColor: "#cdd6f4"
                                                        font.pointSize: 11
                                                    }

                                                    Rectangle {
                                                        id: codeCard
                                                        visible: modelData.type === "code"
                                                        width: parent.width
                                                        height: visible ? codeInner.height + 16 : 0
                                                        radius: 10; color: "#0d0d14"
                                                        border.color: "#313244"; border.width: 1
                                                        property bool copied: false

                                                        Column {
                                                            id: codeInner
                                                            x: 12; y: 8
                                                            width: parent.width - 24
                                                            spacing: 6
                                                            Item {
                                                                width: parent.width; height: 16
                                                                Text {
                                                                    anchors.left: parent.left
                                                                    anchors.verticalCenter: parent.verticalCenter
                                                                    text: (modelData.lang || "code").toUpperCase()
                                                                    color: "#6c7086"; font.pointSize: 8; font.bold: true; font.letterSpacing: 1
                                                                }
                                                                Rectangle {
                                                                    anchors.right: parent.right
                                                                    anchors.verticalCenter: parent.verticalCenter
                                                                    width: copyLbl.width + 18; height: 18; radius: 6
                                                                    color: codeCopyArea.containsMouse ? "#313244" : "transparent"
                                                                    border.color: "#45475a"; border.width: 1
                                                                    Text {
                                                                        id: copyLbl
                                                                        anchors.centerIn: parent
                                                                        text: codeCard.copied ? "✓ Copied" : "⧉ Copy"
                                                                        color: codeCard.copied ? "#a6e3a1" : "#a6adc8"
                                                                        font.pointSize: 8; font.bold: true
                                                                    }
                                                                    MouseArea {
                                                                        id: codeCopyArea
                                                                        anchors.fill: parent
                                                                        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                                        onClicked: {
                                                                            sidebar.copyText(modelData.text);
                                                                            codeCard.copied = true; codeResetTimer.restart();
                                                                        }
                                                                    }
                                                                    Timer { id: codeResetTimer; interval: 1200; onTriggered: codeCard.copied = false }
                                                                }
                                                            }
                                                            TextEdit {
                                                                width: parent.width
                                                                text: (modelData.text || "").replace(/\n+$/, "")
                                                                readOnly: true; selectByMouse: true; persistentSelection: true
                                                                wrapMode: TextEdit.WrapAnywhere
                                                                textFormat: TextEdit.PlainText
                                                                color: "#cdd6f4"; selectionColor: "#585b70"
                                                                font.family: "monospace"; font.pointSize: 10
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        // Clickable file results.
                                        Column {
                                            width: parent.width
                                            spacing: 6
                                            property var files: {
                                                try { return JSON.parse(model.filesJson || "[]"); }
                                                catch (e) { return []; }
                                            }
                                            Repeater {
                                                model: parent.files
                                                delegate: Rectangle {
                                                    width: parent.width
                                                    height: fileRow.height + 12
                                                    radius: 8
                                                    color: fileArea.containsMouse ? "#313244" : "#11111b"
                                                    border.color: "#45475a"; border.width: 1
                                                    Row {
                                                        id: fileRow
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        x: 10; width: parent.width - 20; spacing: 8
                                                        Text {
                                                            text: modelData.is_dir ? "📁" : "📄"
                                                            font.pointSize: 11
                                                            anchors.verticalCenter: parent.verticalCenter
                                                        }
                                                        Column {
                                                            width: parent.width - 30; spacing: 1
                                                            Text {
                                                                width: parent.width; text: modelData.name
                                                                color: "#89b4fa"; font.pointSize: 10; font.bold: true
                                                                elide: Text.ElideMiddle
                                                            }
                                                            Text {
                                                                width: parent.width
                                                                text: (modelData.size ? modelData.size + " · " : "") + modelData.mtime + " · " + modelData.dir
                                                                color: "#6c7086"; font.pointSize: 8; elide: Text.ElideMiddle
                                                            }
                                                        }
                                                    }
                                                    MouseArea {
                                                        id: fileArea
                                                        anchors.fill: parent
                                                        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                        onClicked: sidebar.openFile(modelData.path)
                                                    }
                                                }
                                            }
                                        }

                                        // Confirm + run a gated command.
                                        Rectangle {
                                            visible: isTerminalPrompt
                                            width: parent.width
                                            height: 50; color: "#11111b"; radius: 6
                                            border.color: "#f38ba8"
                                            Row {
                                                anchors.fill: parent; anchors.margins: 10; spacing: 10
                                                Text {
                                                    text: "Run in Terminal:"
                                                    color: "#f38ba8"; font.bold: true
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                                Rectangle {
                                                    height: 30; width: 80; color: "#313244"; radius: 4
                                                    Text { text: "EXECUTE"; color: "white"; anchors.centerIn: parent; font.bold: true; font.pointSize: 9 }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: sidebar.executeCommand(model.content) }
                                                }
                                                Rectangle {
                                                    height: 30; width: 60; color: "#45475a"; radius: 4
                                                    Text { text: "Copy"; color: "white"; anchors.centerIn: parent; font.pointSize: 9 }
                                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: sidebar.copyText(model.content) }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            onCountChanged: chatView.positionViewAtEnd()
                        }
                    }

                    // ---------- Input row ----------
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        TextField {
                            id: inputField
                            Layout.fillWidth: true
                            height: 50
                            placeholderText: "Ask Gideon, or type a command…"
                            placeholderTextColor: "#6c7086"
                            color: "#cdd6f4"; font.pointSize: 11
                            leftPadding: 18; rightPadding: 18
                            selectByMouse: true; selectionColor: "#585b70"
                            background: Rectangle {
                                color: "#313244"; radius: 16
                                border.color: inputField.activeFocus ? "#cba6f7" : "#45475a"
                                border.width: inputField.activeFocus ? 2 : 1
                                Behavior on border.color { ColorAnimation { duration: 150 } }
                            }
                            onAccepted: {
                                var userPrompt = text.trim();
                                if (userPrompt === "") return;

                                chatModel.append({"role": "user", "content": userPrompt, "action": "",
                                                  "filesJson": "[]", "status": "", "thinking": "",
                                                  "thinkingOpen": false, "stats": ""});
                                text = "";
                                chatModel.append({"role": "assistant", "content": "", "action": "",
                                                  "filesJson": "[]", "status": "Thinking…", "thinking": "",
                                                  "thinkingOpen": false, "stats": ""});
                                var aIdx = chatModel.count - 1;
                                sidebar.streamingIdx = aIdx;

                                var xhr = new XMLHttpRequest();
                                sidebar.activeXhr = xhr;
                                var processed = 0;
                                var files = [];

                                function handle(ev) {
                                    if (ev.type === "status") {
                                        chatModel.setProperty(aIdx, "status", "🔧 " + ev.tool + (ev.arg ? " · " + ev.arg : ""));
                                    } else if (ev.type === "files") {
                                        files = files.concat(ev.files || []);
                                        chatModel.setProperty(aIdx, "filesJson", JSON.stringify(files));
                                    } else if (ev.type === "thinking") {
                                        chatModel.setProperty(aIdx, "status", "");
                                        chatModel.setProperty(aIdx, "thinking", chatModel.get(aIdx).thinking + ev.text);
                                        if ((chatModel.get(aIdx).content || "") === "")
                                            chatModel.setProperty(aIdx, "thinkingOpen", true);
                                    } else if (ev.type === "token") {
                                        chatModel.setProperty(aIdx, "status", "");
                                        chatModel.setProperty(aIdx, "thinkingOpen", false);
                                        chatModel.setProperty(aIdx, "content", chatModel.get(aIdx).content + ev.text);
                                        chatView.positionViewAtEnd();
                                    } else if (ev.type === "stats") {
                                        chatModel.setProperty(aIdx, "stats", ev.tok_s + " tok/s");
                                        sidebar.lastTokS = "" + ev.tok_s;
                                    } else if (ev.type === "action") {
                                        chatModel.setProperty(aIdx, "status", "");
                                        chatModel.setProperty(aIdx, "action", "prompt_user");
                                        chatModel.setProperty(aIdx, "content", ev.command);
                                    } else if (ev.type === "error") {
                                        chatModel.setProperty(aIdx, "status", "");
                                        chatModel.setProperty(aIdx, "content", "⚠️ " + ev.message);
                                    }
                                }

                                xhr.onreadystatechange = function() {
                                    if (xhr.readyState === XMLHttpRequest.DONE) sidebar.activeXhr = null;
                                    if (xhr.readyState < XMLHttpRequest.LOADING) return;
                                    var chunk = xhr.responseText.substring(processed);
                                    var nl = chunk.lastIndexOf("\n");
                                    if (nl < 0) return;
                                    processed += nl + 1;
                                    var lines = chunk.substring(0, nl).split("\n");
                                    for (var i = 0; i < lines.length; i++) {
                                        var ln = lines[i].trim();
                                        if (ln === "") continue;
                                        try { handle(JSON.parse(ln)); } catch (e) { /* partial */ }
                                    }
                                }
                                xhr.open("POST", sidebar.apiBase + "/api/chat/stream");
                                xhr.setRequestHeader("Content-Type", "application/json");
                                xhr.send(JSON.stringify({"prompt": userPrompt}));
                            }
                        }
                        // Stop button (only while streaming).
                        Rectangle {
                            visible: sidebar.activeXhr !== null
                            width: 50; height: 50; radius: 16
                            color: stopArea.containsMouse ? "#f38ba8" : "#313244"
                            border.color: "#f38ba8"; border.width: 1
                            Behavior on color { ColorAnimation { duration: 150 } }
                            Text { anchors.centerIn: parent; text: "⏹"; color: "#f38ba8"; font.pointSize: 14 }
                            MouseArea {
                                id: stopArea
                                anchors.fill: parent
                                hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (sidebar.activeXhr) sidebar.activeXhr.abort();
                                    sidebar.activeXhr = null;
                                    if (sidebar.streamingIdx >= 0)
                                        chatModel.setProperty(sidebar.streamingIdx, "status", "⏹ stopped");
                                }
                            }
                        }
                    }
                }

                // =================== SETTINGS ===================
                Flickable {
                    anchors.fill: parent
                    visible: sidebar.activeTab === "settings"
                    contentWidth: width
                    contentHeight: settingsCol.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    Column {
                        id: settingsCol
                        width: parent.width
                        spacing: 16

                        // ---- server power ----
                        Rectangle {
                            id: serverPowerRect
                            width: parent.width
                            radius: 16; color: "#11111b"
                            border.color: sidebar.serverHealthy ? "#a6e3a1" : "#313244"; border.width: 1
                            height: 56

                            Rectangle {
                                id: statusIndicator
                                width: 10; height: 10; radius: 5
                                anchors.left: parent.left
                                anchors.leftMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                color: sidebar.serverHealthy ? "#a6e3a1" : (sidebar.serverRunning ? "#f9e2af" : "#f38ba8")
                            }

                            Column {
                                id: serverTextCol
                                anchors.left: statusIndicator.right
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.right: powerToggle.left
                                anchors.rightMargin: 10

                                Text {
                                    width: parent.width
                                    text: "llama-server"
                                    color: "#cdd6f4"
                                    font.pointSize: 11
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: parent.width
                                    text: sidebar.serverHealthy ? ("running · " + sidebar.serverModel)
                                          : sidebar.serverRunning ? "loading…" : "stopped (not using VRAM/RAM)"
                                    color: "#6c7086"
                                    font.pointSize: 8
                                    elide: Text.ElideRight
                                }
                            }

                            // power toggle
                            Rectangle {
                                id: powerToggle
                                width: 52; height: 26; radius: 13
                                anchors.right: parent.right
                                anchors.rightMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                color: sidebar.serverRunning ? "#a6e3a1" : "#45475a"
                                opacity: sidebar.applying ? 0.5 : 1.0
                                Behavior on color { ColorAnimation { duration: 150 } }
                                Rectangle {
                                    width: 22; height: 22; radius: 11; color: "#1e1e2e"
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: sidebar.serverRunning ? parent.width - width - 2 : 2
                                    Behavior on x { NumberAnimation { duration: 150 } }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    enabled: !sidebar.applying
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: sidebar.setServer(!sidebar.serverRunning)
                                }
                            }
                        }

                        // ---- usage panel ----
                        Rectangle {
                            width: parent.width
                            radius: 16; color: "#11111b"
                            border.color: "#313244"; border.width: 1
                            height: usageCol.height + 28
                            Column {
                                id: usageCol
                                x: 14; y: 14; width: parent.width - 28; spacing: 12
                                Text { text: "ESTIMATED USAGE"; color: "#6c7086"; font.pointSize: 8; font.bold: true; font.letterSpacing: 1 }

                                Column {
                                    width: parent.width; spacing: 4
                                    Item {
                                        width: parent.width; height: vramTitleText.implicitHeight
                                        Text {
                                            id: vramTitleText
                                            text: "VRAM"; color: "#cdd6f4"; font.pointSize: 10; font.bold: true
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        Text {
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            horizontalAlignment: Text.AlignRight
                                            text: sidebar.gbStr(sidebar.estVram) + " / " + sidebar.gbStr(sidebar.estVramTotal) + " GB  est"
                                            color: sidebar.estVramOom ? "#f38ba8" : "#a6adc8"; font.pointSize: 9
                                        }
                                    }
                                    Rectangle {
                                        width: parent.width; height: 14; radius: 7; color: "#313244"
                                        Rectangle {
                                            height: parent.height; radius: 7
                                            width: Math.min(1, sidebar.estVram / Math.max(1, sidebar.estVramTotal)) * parent.width
                                            color: sidebar.barColor(sidebar.estVram, sidebar.estVramTotal, sidebar.estVramOom)
                                            Behavior on width { NumberAnimation { duration: 200 } }
                                        }
                                        Rectangle {
                                            width: 2; height: parent.height + 6; y: -3; color: "#89b4fa"
                                            x: Math.min(1, sidebar.liveVramUsed / Math.max(1, sidebar.liveVramTotal)) * parent.width
                                        }
                                    }
                                    Text { text: "live: " + sidebar.gbStr(sidebar.liveVramUsed) + " GB used now (blue tick)"; color: "#6c7086"; font.pointSize: 8 }
                                }

                                Column {
                                    width: parent.width; spacing: 4
                                    Item {
                                        width: parent.width; height: ramTitleText.implicitHeight
                                        Text {
                                            id: ramTitleText
                                            text: "RAM"; color: "#cdd6f4"; font.pointSize: 10; font.bold: true
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        Text {
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            horizontalAlignment: Text.AlignRight
                                            text: sidebar.gbStr(sidebar.estRam) + " / " + sidebar.gbStr(sidebar.estRamTotal) + " GB  est"
                                            color: sidebar.estRamOom ? "#f38ba8" : "#a6adc8"; font.pointSize: 9
                                        }
                                    }
                                    Rectangle {
                                        width: parent.width; height: 14; radius: 7; color: "#313244"
                                        Rectangle {
                                            height: parent.height; radius: 7
                                            width: Math.min(1, sidebar.estRam / Math.max(1, sidebar.estRamTotal)) * parent.width
                                            color: sidebar.barColor(sidebar.estRam, sidebar.estRamTotal, sidebar.estRamOom)
                                            Behavior on width { NumberAnimation { duration: 200 } }
                                        }
                                        Rectangle {
                                            width: 2; height: parent.height + 6; y: -3; color: "#89b4fa"
                                            x: Math.min(1, sidebar.liveRamUsed / Math.max(1, sidebar.liveRamTotal)) * parent.width
                                        }
                                    }
                                    Text { text: "live: " + sidebar.gbStr(sidebar.liveRamUsed) + " GB used now"; color: "#6c7086"; font.pointSize: 8 }
                                }

                                Rectangle {
                                    width: parent.width
                                    visible: sidebar.estVramOom || sidebar.estRamOom
                                    height: oomTxt.height + 16; radius: 8
                                    color: "#2d1620"; border.color: "#f38ba8"; border.width: 1
                                    Text {
                                        id: oomTxt
                                        x: 10; y: 8; width: parent.width - 20; wrapMode: Text.Wrap
                                        color: "#f38ba8"; font.pointSize: 9
                                        text: "⚠ This config is estimated to exceed your "
                                            + (sidebar.estVramOom && sidebar.estRamOom ? "VRAM and RAM"
                                               : sidebar.estVramOom ? "VRAM" : "RAM")
                                            + " — it will likely OOM. Lower the context size, increase CPU expert offload, or pick a smaller model."
                                    }
                                }
                            }
                        }

                        // ---- models directory ----
                        Column {
                            width: parent.width; spacing: 6
                            Text { text: "MODELS FOLDER"; color: "#6c7086"; font.pointSize: 8; font.bold: true; font.letterSpacing: 1 }
                            Row {
                                width: parent.width; spacing: 8
                                Rectangle {
                                    width: parent.width - scanBtn.width - 8; height: 38; radius: 12
                                    color: "#313244"; border.color: dirField.activeFocus ? "#cba6f7" : "#45475a"; border.width: 1
                                    TextInput {
                                        id: dirField
                                        anchors.fill: parent
                                        anchors.leftMargin: 14; anchors.rightMargin: 14
                                        verticalAlignment: TextInput.AlignVCenter
                                        clip: true
                                        color: "#cdd6f4"; font.pointSize: 10
                                        selectByMouse: true
                                        selectionColor: "#cba6f7"
                                        text: sidebar.cfgModelsDir
                                        onAccepted: sidebar.setModelsDir(text)
                                        // Re-sync when the backend reports a new dir, unless the user is editing.
                                        Connections {
                                            target: sidebar
                                            function onCfgModelsDirChanged() {
                                                if (!dirField.activeFocus) dirField.text = sidebar.cfgModelsDir;
                                            }
                                        }
                                    }
                                }
                                Rectangle {
                                    id: scanBtn
                                    width: 64; height: 38; radius: 12
                                    color: scanMa.containsMouse ? "#cba6f7" : "#45475a"
                                    Text { anchors.centerIn: parent; text: "Scan"; color: scanMa.containsMouse ? "#1e1e2e" : "#cdd6f4"; font.pointSize: 9; font.bold: true }
                                    MouseArea {
                                        id: scanMa; anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: sidebar.setModelsDir(dirField.text)
                                    }
                                }
                            }
                            Text {
                                visible: sidebar.modelsDirStatus !== ""
                                width: parent.width; wrapMode: Text.Wrap
                                text: sidebar.modelsDirStatus
                                color: sidebar.modelsDirStatus.indexOf("⚠") === 0 ? "#f38ba8" : "#a6e3a1"
                                font.pointSize: 8
                            }
                        }

                        // ---- model selector ----
                        Column {
                            width: parent.width; spacing: 6
                            Text { text: "MODEL"; color: "#6c7086"; font.pointSize: 8; font.bold: true; font.letterSpacing: 1 }
                            ComboBox {
                                id: modelBox
                                width: parent.width
                                model: sidebar.availableModels.map(function(m) {
                                    return m.name + "  (" + m.size_human + (m.moe ? ", MoE" : "") + ")";
                                })
                                currentIndex: {
                                    for (var i = 0; i < sidebar.availableModels.length; i++)
                                        if (sidebar.availableModels[i].path === sidebar.cfgModelPath) return i;
                                    return -1;
                                }
                                onActivated: function(idx) {
                                    var m = sidebar.availableModels[idx];
                                    if (!m) return;
                                    sidebar.cfgModelPath = m.path;
                                    sidebar.cfgModelIsMoe = m.moe;
                                    sidebar.cfgModelLayers = m.layers;
                                    sidebar.requestEstimate();
                                }
                                background: Rectangle { radius: 12; color: "#313244"; border.color: "#45475a"; border.width: 1 }
                                contentItem: Text {
                                    leftPadding: 14; rightPadding: 30; text: modelBox.displayText
                                    color: "#cdd6f4"; font.pointSize: 10
                                    verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                                }
                                delegate: ItemDelegate {
                                    width: modelBox.width
                                    contentItem: Text { text: modelData; color: "#cdd6f4"; font.pointSize: 10; elide: Text.ElideRight; verticalAlignment: Text.AlignVCenter }
                                    highlighted: modelBox.highlightedIndex === index
                                    background: Rectangle { color: highlighted ? "#313244" : "#1e1e2e" }
                                }
                                popup: Popup {
                                    y: modelBox.height + 4; width: modelBox.width
                                    implicitHeight: Math.min(contentItem.implicitHeight, 240); padding: 1
                                    contentItem: ListView {
                                        clip: true; implicitHeight: contentHeight
                                        model: modelBox.popup.visible ? modelBox.delegateModel : null
                                        ScrollIndicator.vertical: ScrollIndicator {}
                                    }
                                    background: Rectangle { radius: 12; color: "#1e1e2e"; border.color: "#45475a"; border.width: 1 }
                                }
                            }
                        }

                        // ---- context size ----
                        Column {
                            width: parent.width; spacing: 6
                            Item {
                                width: parent.width; height: ctxTitleText.implicitHeight
                                Text {
                                    id: ctxTitleText
                                    text: "CONTEXT SIZE"; color: "#6c7086"; font.pointSize: 8; font.bold: true; font.letterSpacing: 1
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    horizontalAlignment: Text.AlignRight
                                    text: sidebar.cfgCtx + " tok"
                                    color: "#cba6f7"; font.pointSize: 10; font.bold: true
                                }
                            }
                            Slider {
                                id: ctxSlider
                                width: parent.width
                                from: 1024; to: 32768; stepSize: 1024
                                value: sidebar.cfgCtx
                                onMoved: { sidebar.cfgCtx = Math.round(value); estimateTimer.restart(); }
                                background: Rectangle {
                                    x: ctxSlider.leftPadding; y: ctxSlider.topPadding + ctxSlider.availableHeight / 2 - 3
                                    width: ctxSlider.availableWidth; height: 6; radius: 3; color: "#313244"
                                    Rectangle { width: ctxSlider.visualPosition * parent.width; height: parent.height; radius: 3; color: "#cba6f7" }
                                }
                                handle: Rectangle {
                                    x: ctxSlider.leftPadding + ctxSlider.visualPosition * (ctxSlider.availableWidth - width)
                                    y: ctxSlider.topPadding + ctxSlider.availableHeight / 2 - height / 2
                                    width: 18; height: 18; radius: 9; color: "#cdd6f4"; border.color: "#cba6f7"; border.width: 2
                                }
                            }
                        }

                        // ---- KV cache quant ----
                        Row {
                            width: parent.width; spacing: 12
                            Column {
                                width: (parent.width - 12) / 2; spacing: 6
                                Text { text: "KV CACHE — K"; color: "#6c7086"; font.pointSize: 8; font.bold: true; font.letterSpacing: 1 }
                                ComboBox {
                                    id: kvkBox
                                    width: parent.width
                                    model: ["q8_0", "f16"]
                                    currentIndex: Math.max(0, model.indexOf(sidebar.cfgKvK))
                                    onActivated: function(i) { sidebar.cfgKvK = kvkBox.model[i]; sidebar.requestEstimate(); }
                                    background: Rectangle { radius: 12; color: "#313244"; border.color: "#45475a"; border.width: 1 }
                                    contentItem: Text { leftPadding: 12; text: kvkBox.displayText; color: "#cdd6f4"; font.pointSize: 10; verticalAlignment: Text.AlignVCenter }
                                }
                            }
                            Column {
                                width: (parent.width - 12) / 2; spacing: 6
                                Text { text: "KV CACHE — V"; color: "#6c7086"; font.pointSize: 8; font.bold: true; font.letterSpacing: 1 }
                                ComboBox {
                                    id: kvvBox
                                    width: parent.width
                                    model: ["turbo4", "turbo3", "turbo2", "q8_0", "f16"]
                                    currentIndex: Math.max(0, model.indexOf(sidebar.cfgKvV))
                                    onActivated: function(i) { sidebar.cfgKvV = kvvBox.model[i]; sidebar.requestEstimate(); }
                                    background: Rectangle { radius: 12; color: "#313244"; border.color: "#45475a"; border.width: 1 }
                                    contentItem: Text { leftPadding: 12; text: kvvBox.displayText; color: "#cdd6f4"; font.pointSize: 10; verticalAlignment: Text.AlignVCenter }
                                }
                            }
                        }

                        // ---- MoE expert CPU offload (MoE models only) ----
                        Column {
                            width: parent.width; spacing: 6
                            visible: sidebar.cfgModelIsMoe
                            Item {
                                width: parent.width; height: moeTitleText.implicitHeight
                                Text {
                                    id: moeTitleText
                                    text: "MoE EXPERT CPU OFFLOAD"; color: "#6c7086"; font.pointSize: 8; font.bold: true; font.letterSpacing: 1
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    horizontalAlignment: Text.AlignRight
                                    text: sidebar.cfgNCpuMoe + " / " + sidebar.cfgModelLayers + " layers"
                                    color: "#cba6f7"; font.pointSize: 10; font.bold: true
                                }
                            }
                            Slider {
                                id: moeSlider
                                width: parent.width
                                from: 0; to: sidebar.cfgModelLayers; stepSize: 1
                                value: sidebar.cfgNCpuMoe
                                onMoved: { sidebar.cfgNCpuMoe = Math.round(value); estimateTimer.restart(); }
                                background: Rectangle {
                                    x: moeSlider.leftPadding; y: moeSlider.topPadding + moeSlider.availableHeight / 2 - 3
                                    width: moeSlider.availableWidth; height: 6; radius: 3; color: "#313244"
                                    Rectangle { width: moeSlider.visualPosition * parent.width; height: parent.height; radius: 3; color: "#cba6f7" }
                                }
                                handle: Rectangle {
                                    x: moeSlider.leftPadding + moeSlider.visualPosition * (moeSlider.availableWidth - width)
                                    y: moeSlider.topPadding + moeSlider.availableHeight / 2 - height / 2
                                    width: 18; height: 18; radius: 9; color: "#cdd6f4"; border.color: "#cba6f7"; border.width: 2
                                }
                            }
                            Text { width: parent.width; wrapMode: Text.Wrap; text: "Higher = more experts on CPU RAM → less VRAM, slower. Lower = faster, more VRAM."; color: "#6c7086"; font.pointSize: 8 }
                        }

                        // ---- flags ----
                        Column {
                            width: parent.width; spacing: 8
                            Text { text: "FLAGS"; color: "#6c7086"; font.pointSize: 8; font.bold: true; font.letterSpacing: 1 }
                            Repeater {
                                model: [
                                    { "key": "flash_attn", "label": "Flash Attention", "hint": "faster, less KV memory" },
                                    { "key": "mlock", "label": "Memory Lock (mlock)", "hint": "pin weights in RAM, no swap" },
                                    { "key": "no_mmap", "label": "Disable mmap", "hint": "load fully into RAM upfront" }
                                ]
                                delegate: Row {
                                    width: settingsCol.width; spacing: 10
                                    property bool checked: modelData.key === "flash_attn" ? sidebar.cfgFlashAttn
                                                          : modelData.key === "mlock" ? sidebar.cfgMlock
                                                          : sidebar.cfgNoMmap
                                    Rectangle {
                                        width: 42; height: 22; radius: 11
                                        color: parent.checked ? "#a6e3a1" : "#45475a"
                                        anchors.verticalCenter: parent.verticalCenter
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                        Rectangle {
                                            width: 18; height: 18; radius: 9; color: "#1e1e2e"
                                            anchors.verticalCenter: parent.verticalCenter
                                            x: parent.parent.checked ? parent.width - width - 2 : 2
                                            Behavior on x { NumberAnimation { duration: 150 } }
                                        }
                                        MouseArea {
                                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (modelData.key === "flash_attn") sidebar.cfgFlashAttn = !sidebar.cfgFlashAttn;
                                                else if (modelData.key === "mlock") sidebar.cfgMlock = !sidebar.cfgMlock;
                                                else sidebar.cfgNoMmap = !sidebar.cfgNoMmap;
                                                sidebar.requestEstimate();
                                            }
                                        }
                                    }
                                    Column {
                                        anchors.verticalCenter: parent.verticalCenter; spacing: 0
                                        Text { text: modelData.label; color: "#cdd6f4"; font.pointSize: 10 }
                                        Text { text: modelData.hint; color: "#6c7086"; font.pointSize: 8 }
                                    }
                                }
                            }
                        }

                        // ---- apply ----
                        Rectangle {
                            width: parent.width; height: 44; radius: 12
                            color: applyArea.containsMouse ? "#b4befe" : "#cba6f7"
                            opacity: sidebar.applying ? 0.5 : 1.0
                            Behavior on color { ColorAnimation { duration: 150 } }
                            Text {
                                anchors.centerIn: parent
                                text: sidebar.applying ? "Applying…"
                                     : (sidebar.estVramOom || sidebar.estRamOom) ? "Apply anyway (OOM risk)"
                                     : "Apply & Restart Server"
                                color: "#1e1e2e"; font.pointSize: 11; font.bold: true
                            }
                            MouseArea {
                                id: applyArea
                                anchors.fill: parent
                                hoverEnabled: true; enabled: !sidebar.applying
                                cursorShape: Qt.PointingHandCursor
                                onClicked: sidebar.applyConfig()
                            }
                        }

                        Text {
                            width: parent.width
                            visible: sidebar.applyStatus !== ""
                            wrapMode: Text.Wrap
                            text: sidebar.applyStatus
                            color: sidebar.applyStatus.indexOf("✓") === 0 ? "#a6e3a1" : "#f9e2af"
                            font.pointSize: 9
                        }
                        Item { width: 1; height: 8 }
                    }
                }
            }
        }
    }

    Component.onCompleted: sidebar.refreshServerStatus();
}
