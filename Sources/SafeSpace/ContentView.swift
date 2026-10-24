import SwiftUI
#if canImport(SafeSpaceCore)
import SafeSpaceCore
#endif

enum AppLanguage: String, CaseIterable, Identifiable { case english = "English", vietnamese = "Tiếng Việt"; var id: String { rawValue } }

struct ContentView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appLanguage") private var language = AppLanguage.english.rawValue
    @AppStorage("deepScan") private var deepScan = false
    @State private var section: String? = "cache"
    @State private var pending: [DiskEntry] = []
    @State private var showCleanSheet = false
    @State private var showAccessGuide = false
    @State private var showCoffee = false
    @State private var acknowledged = false
    @State private var reviewPhrase = ""
    @State private var pendingDocker: DockerAction?
    @State private var dockerAcknowledged = false
    @State private var volumePhrase = ""
    @State private var filter = ""
    private var vi: Bool { language == AppLanguage.vietnamese.rawValue }
    private func t(_ en: String, _ vn: String) -> String { vi ? vn : en }
    private var groups: [DiskGroup] { DiskGroup.all + (deepScan || model.results[DiskGroup.wholeDisk.id] != nil ? [DiskGroup.wholeDisk] : []) }
    private var group: DiskGroup { groups.first { $0.id == section } ?? DiskGroup.all[0] }
    private var currentResult: GroupResult? { model.openedResult ?? model.results[group.id] }
    private var entries: [DiskEntry] { (currentResult?.entries ?? []).filter { filter.isEmpty || $0.url.lastPathComponent.localizedCaseInsensitiveContains(filter) } }

    var body: some View {
        NavigationSplitView { sidebar } detail: {
            VStack(spacing: 0) {
                summary.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 18)
                Divider()
                if section == "docker" { dockerPanel } else { storagePanel }
                Divider()
                HStack(spacing: 10) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { model.showActivity = true } label: { Label(t("Activity", "Nhật ký"), systemImage: "clock.arrow.circlepath") }.buttonStyle(.borderless).font(.caption)
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }.background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(section == "docker" ? "Docker" : title(of: group))
        }
        .tint(.blue)
        .toolbar {
            ToolbarItemGroup {
                if model.isScanning {
                    Button { model.cancel() } label: { Label(t("Stop scan", "Dừng quét"), systemImage: "stop.circle") }.help(t("Stop scan", "Dừng quét"))
                } else {
                    Button { section == "docker" ? model.refreshDocker() : model.scan() } label: { Label(model.lastScan == nil ? t("Scan", "Quét") : t("Rescan", "Quét lại"), systemImage: model.lastScan == nil ? "magnifyingglass" : "arrow.clockwise") }
                        .help(t("Scan all storage categories", "Quét tất cả nhóm dung lượng")).disabled(model.busy).keyboardShortcut("r")
                }
                Button { model.reveal(section == "docker" ? model.home.appendingPathComponent("Library/Containers/com.docker.docker") : (model.openedFolder ?? group.root(home: model.home))) } label: { Label(t("Open in Finder", "Mở Finder"), systemImage: "folder") }.help(t("Open in Finder", "Mở Finder"))
                Menu {
                    Picker(t("Display language", "Ngôn ngữ hiển thị"), selection: $language) { ForEach(AppLanguage.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    Divider()
                    Toggle(t("Deep scan (whole disk, Desktop, Documents, Downloads)", "Quét sâu (toàn bộ ổ đĩa, Desktop, Documents, Downloads)"), isOn: $deepScan)
                    Button(t("Deep scan & access guide", "Hướng dẫn quét sâu và quyền truy cập")) { showAccessGuide = true }
                } label: { Label(t("Settings", "Cài đặt"), systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $showCleanSheet) { cleanConfirmation }
        .sheet(isPresented: $showAccessGuide) { accessGuide }
        .sheet(item: $pendingDocker) { dockerConfirmation($0) }
        .sheet(isPresented: $model.showActivity) { activitySheet }
        .onChange(of: section) { _ in model.closeFolder(); filter = "" }
        .onChange(of: deepScan) { on in if !on && section == DiskGroup.wholeDisk.id { section = "home" } }
    }

    // Category names live in SafeSpaceCore in English; translate them here for display.
    private func title(of group: DiskGroup) -> String {
        guard vi else { return group.title }
        switch group.id {
        case "cache": return "Bộ nhớ đệm app"
        case "gradle": return "Bộ nhớ đệm build"
        case "logs": return "File log"
        case "developer": return "Công cụ dev & simulator"
        case "android": return "Công cụ Android & emulator"
        case "arduino": return "Công cụ Arduino"
        case "support": return "Ứng dụng & dữ liệu"
        case "home": return "Thư mục cá nhân lớn"
        case "disk": return "Toàn bộ ổ đĩa"
        default: return group.title
        }
    }
    private func note(of group: DiskGroup) -> String {
        guard vi else { return group.note }
        switch group.id {
        case "cache": return "Dữ liệu tạm của app. Hãy đóng app liên quan trước."
        case "gradle": return "Thư viện có thể được tải lại ở lần build tiếp theo."
        case "logs": return "Giữ lại log bạn cần để gỡ lỗi."
        case "developer": return "Dữ liệu Xcode và simulator. Xem kỹ từng mục."
        case "android": return "Dữ liệu SDK và emulator. Xem kỹ từng mục."
        case "arduino": return "Gói board và công cụ. Xem kỹ từng mục."
        case "support": return "Dữ liệu app có thể gồm database, file tải về và nội dung tài khoản."
        case "home": return "Các thư mục lớn trong thư mục người dùng, trừ thư mục hệ thống ẩn."
        case "disk": return "Mọi thứ trên ổ khởi động. Chỉ xem: mở từng thư mục để tìm phần chiếm nhiều dung lượng."
        default: return group.note
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Fuk Mac Storage", systemImage: "internaldrive.fill").font(.title2.bold()).foregroundStyle(.blue).padding(.horizontal, 16).padding(.top, 18)
            Text(t("STORAGE, UNDER CONTROL", "QUẢN LÝ DUNG LƯỢNG")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16)
            List(selection: $section) {
                Section(t("Storage categories", "Nhóm dung lượng")) { ForEach(DiskGroup.all) { sidebarRow($0) } }
                if groups.contains(where: { $0.id == DiskGroup.wholeDisk.id }) { Section(t("Deep scan", "Quét sâu")) { sidebarRow(DiskGroup.wholeDisk) } }
                if model.docker != nil { Section("Docker") { Label("Docker", systemImage: "shippingbox.fill").tag("docker") } }
            }.listStyle(.sidebar)
            if !AppModel.isSandboxed { coffeeButton }
            VStack(alignment: .leading, spacing: 10) {
                Label(t("Nothing is selected automatically", "Không tự chọn để xoá"), systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Created by zellkon")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }.padding(16)
        }.navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 310)
    }
    // Tip link: App Store rule 3.1.1 requires In-App Purchase for tips, so the sandboxed
    // (App Store) build hides it.
    private var coffeeButton: some View {
        Button { showCoffee.toggle() } label: {
            Text("☕️").font(.system(size: 24))
                .frame(width: 44, height: 44)
                .background(Color.orange.opacity(0.12), in: Circle())
                .overlay(alignment: .bottomTrailing) {
                    Text("✨").font(.system(size: 12)).allowsHitTesting(false)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("Buy zellkon a coffee", "Mời zellkon một ly cà phê"))
        .help(t("A little caffeine for the creator ☕", "Tiếp caffeine cho tác giả ☕"))
        .popover(isPresented: $showCoffee, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(t("Coffee break? ☕", "Nghỉ tay, cà phê nhé? ☕")).font(.headline)
                    Spacer()
                    Button { showCoffee = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(t("Close", "Đóng"))
                }
                Text(t("Your Mac runs on electricity, I run on caffeine — when the coffee runs out, the bugs fight back! 😄", "Mac chạy bằng điện, mình chạy bằng caffeine — hết cà phê là bug có cơ hội phản công! 😄"))
                    .font(.callout).foregroundStyle(.secondary)
                Link(t("Buy zellkon a coffee ☕", "Mua cho zellkon một ly cà phê ☕"), destination: URL(string: "https://buymeacoffee.com/zellkon")!)
                    .font(.callout.weight(.semibold))
            }.padding(20).frame(width: 320)
        }
        .padding(.horizontal, 16)
    }
    private func sidebarRow(_ group: DiskGroup) -> some View {
        HStack {
            Label(title(of: group), systemImage: group.icon).lineLimit(1)
            Spacer()
            if let result = model.results[group.id] { Text(formattedBytes(result.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
            else if model.isScanning { ProgressView().controlSize(.mini) }
        }.tag(group.id)
    }
    private var hasScanned: Bool { !model.results.isEmpty }
    private var summary: some View {
        HStack(spacing: 14) {
            MetricCard(icon: "internaldrive", title: t("Available storage", "Dung lượng trống"), value: model.freeBytes > 0 ? formattedBytes(model.freeBytes) : "—", tint: model.usedFraction > 0.9 ? .red : .primary) {
                if model.totalBytes > 0 {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: model.usedFraction).tint(model.usedFraction > 0.9 ? .red : (model.usedFraction > 0.75 ? .orange : .blue))
                        Text(t("\(formattedBytes(model.totalBytes - model.freeBytes)) used of \(formattedBytes(model.totalBytes))", "Đã dùng \(formattedBytes(model.totalBytes - model.freeBytes)) / \(formattedBytes(model.totalBytes))")).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            MetricCard(icon: "magnifyingglass", title: t("Found in scan", "Tìm thấy khi quét"), value: hasScanned ? formattedBytes(model.cacheBytes) : "—", tint: .primary) {
                Text(hasScanned ? t("\(model.results.count) of \(groups.count) categories scanned", "Đã quét \(model.results.count)/\(groups.count) nhóm") : t("Run a scan to measure", "Quét để đo dung lượng")).font(.caption2).foregroundStyle(.secondary)
            }
            MetricCard(icon: "trash", title: t("Ready to clean", "Sẵn sàng dọn"), value: model.selected.isEmpty ? "—" : formattedBytes(model.selectedBytes), tint: model.selected.isEmpty ? .primary : .blue) {
                Text(model.selected.isEmpty ? t("Nothing selected yet", "Chưa chọn mục nào") : t("\(model.chosen.count) items • moves to Trash first", "\(model.chosen.count) mục • chuyển vào Thùng rác trước")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private var storagePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if let folder = model.openedFolder {
                    HStack(spacing: 6) {
                        Button { model.closeFolder() } label: { Label(title(of: group), systemImage: "chevron.left") }.buttonStyle(.borderless)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(folder.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                    }.font(.callout)
                    Text(folder.lastPathComponent).font(.title2.bold()).lineLimit(1)
                } else { Text(title(of: group)).font(.title2.bold()) }
                Text(model.openedFolder == nil ? note(of: group) : t("Select a folder to scan one level deeper.", "Chọn thư mục để quét sâu thêm một cấp.")).font(.callout).foregroundStyle(.secondary)
            }
            if group.id == "home" && !deepScan && model.openedFolder == nil {
                notice(icon: "lock.shield", text: t("Desktop, Documents and Downloads are skipped so macOS does not ask for access. Turn on Deep scan to include them.", "Desktop, Documents và Downloads đang được bỏ qua để macOS không hỏi quyền. Bật Quét sâu để quét cả các thư mục này."), button: t("Turn on Deep scan", "Bật Quét sâu")) { deepScan = true }
            }
            if group.id == DiskGroup.wholeDisk.id && !model.diskAccess {
                notice(icon: "lock.shield", text: t("To measure the whole disk, allow access to your startup disk once. The App Store version can only read what you select.", "Để đo toàn bộ ổ đĩa, hãy cho phép truy cập ổ khởi động một lần. Bản App Store chỉ đọc được những gì bạn chọn."), button: t("Allow disk access…", "Cho phép truy cập ổ…")) { if model.requestAccess(disk: true) { model.scan() } }
            }
            if group.id == DiskGroup.wholeDisk.id {
                notice(icon: "eye", text: t("Read-only overview. Open folders to find what is large, then clean it from its category or in Finder. For complete sizes, grant Full Disk Access once (see Settings → Deep scan & access guide).", "Chỉ để xem. Mở từng thư mục để tìm phần chiếm nhiều dung lượng, rồi dọn ở nhóm tương ứng hoặc trong Finder. Để đo đủ, hãy cấp Full Disk Access một lần (xem Cài đặt → Hướng dẫn quét sâu)."), button: nil, action: nil)
            }
            if let result = currentResult {
                if !result.issues.isEmpty {
                    Label(t("Some items could not be fully scanned. Their size is partial; cleaning needs an extra confirmation.", "Một số mục chưa quét đủ. Dung lượng là một phần; dọn cần xác nhận thêm."), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(t("Search items…", "Tìm mục…"), text: $filter).textFieldStyle(.plain)
                        if !filter.isEmpty { Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
                    }.padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: 320)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))
                    Spacer()
                    Text("\(entries.count) " + t("items", "mục") + " • " + formattedBytes(entries.reduce(0) { $0 + $1.bytes })).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if entries.isEmpty {
                    emptyState(icon: filter.isEmpty ? "checkmark.seal" : "magnifyingglass", title: filter.isEmpty ? t("Nothing to clean here", "Không có gì để dọn") : t("No matching items", "Không có mục phù hợp"), detail: filter.isEmpty ? t("This category is empty or could not be read.", "Nhóm này trống hoặc không đọc được.") : t("Try a different search.", "Thử từ khoá khác."))
                } else {
                    let largest = max(entries.map(\.bytes).max() ?? 1, 1)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                EntryRow(entry: entry, fraction: Double(entry.bytes) / Double(largest), selected: model.selected.contains(entry.id), opening: model.openingFolder == entry.url, disabled: model.busy, t: t,
                                         toggle: { if model.selected.contains(entry.id) { model.selected.remove(entry.id) } else { model.selected.insert(entry.id) } },
                                         open: { model.openFolder(entry, group: group) }, reveal: { model.reveal(entry.url) })
                                if entry.id != entries.last?.id { Divider().padding(.leading, 44) }
                            }
                        }.padding(.vertical, 4)
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                    .overlay { if let folder = model.openingFolder { openingOverlay(folder) } }
                }
            } else if !model.homeAccess {
                emptyState(icon: "folder.badge.person.crop", title: t("Allow access to your home folder", "Cho phép truy cập thư mục cá nhân"), detail: t("Fuk Mac Storage runs in the App Sandbox and can only measure folders you choose. Select your home folder “\(model.home.lastPathComponent)” once; access is remembered.", "Fuk Mac Storage chạy trong App Sandbox và chỉ đo được thư mục bạn chọn. Hãy chọn thư mục cá nhân “\(model.home.lastPathComponent)” một lần; quyền sẽ được ghi nhớ."), action: (t("Choose Home Folder…", "Chọn thư mục cá nhân…"), { if model.requestAccess() { model.scan() } }))
            } else if model.isScanning {
                emptyState(icon: "hourglass", title: t("Scanning…", "Đang quét…"), detail: t("Categories appear in the sidebar as soon as they are measured.", "Mỗi nhóm hiện ở thanh bên ngay khi đo xong."), spinner: true)
            } else {
                emptyState(icon: "internaldrive.badge.magnifyingglass", title: t("Scan your Mac to begin", "Quét máy Mac để bắt đầu"), detail: t("We only read storage information until you choose an item.", "App chỉ đọc dung lượng cho đến khi bạn chọn mục."), action: model.busy ? nil : (t("Scan storage", "Quét dung lượng"), { model.scan() }))
            }
            HStack(spacing: 10) {
                Button(t("Select all", "Chọn tất cả")) { entries.filter(\.eligible).forEach { model.selected.insert($0.id) } }.disabled(entries.filter(\.eligible).isEmpty || model.busy)
                Button(t("Clear selection", "Bỏ chọn")) { model.selected.removeAll() }.disabled(model.selected.isEmpty || model.busy)
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                    .help(t("Size is an estimate. APFS snapshots, clones and hard links can make the actual recovered space different.", "Dung lượng là ước tính; APFS snapshots, clones và hard links có thể làm dung lượng thực khác."))
                Spacer()
                if !model.selected.isEmpty { Text("\(model.chosen.count) " + t("items", "mục") + " • " + formattedBytes(model.selectedBytes)).font(.callout.weight(.medium)).monospacedDigit() }
                Button { pending = model.chosen.sorted { $0.url.path < $1.url.path }; acknowledged = false; reviewPhrase = ""; showCleanSheet = true } label: { Label(t("Clean selected…", "Dọn mục đã chọn…"), systemImage: "trash") }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.selected.isEmpty || model.busy)
            }
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }
    private func openingOverlay(_ folder: URL) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(t("Opening “\(folder.lastPathComponent)”…", "Đang mở “\(folder.lastPathComponent)”…")).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(t("Measuring every item inside. Large folders can take a while.", "Đang đo từng mục bên trong. Thư mục lớn có thể mất một lúc.")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(t("Cancel", "Huỷ")) { model.cancel() }.controlSize(.large).keyboardShortcut(.cancelAction)
            }
            .padding(28).frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        }
        .transition(.opacity)
    }
    private func notice(icon: String, text: String, button: String?, action: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.blue)
            Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if let button, let action { Button(button, action: action).controlSize(.small).fixedSize() }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
    private func emptyState(icon: String, title: String, detail: String, spinner: Bool = false, action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 10) {
            if spinner { ProgressView().controlSize(.large).padding(.bottom, 4) }
            else { Image(systemName: icon).font(.system(size: 40, weight: .light)).foregroundStyle(.blue) }
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action { Button(action.0, action: action.1).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var cleanConfirmation: some View {
        let requiresReview = pending.contains(where: \.needsExtraConfirmation)
        return VStack(alignment: .leading, spacing: 16) { Label(t("Move selected items to Trash?", "Chuyển mục đã chọn vào Thùng rác?"), systemImage: "trash").font(.title2.bold()).foregroundStyle(.blue); Text("\(pending.count) " + t("items", "mục") + " • " + formattedBytes(pending.reduce(0) { $0 + $1.bytes })); Text(t("The selected folders and their current contents will move to Trash. Storage becomes available only after you empty Trash yourself.", "Các thư mục đã chọn và nội dung hiện có sẽ được chuyển vào Thùng rác. Dung lượng chỉ trống sau khi bạn tự làm trống Thùng rác.")).foregroundStyle(.secondary); ScrollView { VStack(alignment: .leading, spacing: 7) { ForEach(pending) { Text($0.url.lastPathComponent).font(.system(.caption, design: .monospaced)) } }.frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 150); Toggle(t("I closed related apps and stopped active builds.", "Tôi đã đóng app liên quan và dừng build."), isOn: $acknowledged); if requiresReview { TextField(t("Type REMOVE to confirm app/developer data", "Gõ REMOVE để xác nhận dữ liệu app/dev"), text: $reviewPhrase).textFieldStyle(.roundedBorder) }; HStack { Button(t("Cancel", "Huỷ")) { showCleanSheet = false }.keyboardShortcut(.cancelAction); Spacer(); Button(t("Move to Trash", "Chuyển vào Thùng rác"), role: .destructive) { showCleanSheet = false; model.clean(pending) }.disabled(!acknowledged || (requiresReview && reviewPhrase != "REMOVE")) } }.padding(26).frame(width: 650)
    }
    private var dockerPanel: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) { HStack { Text("Docker").font(.title.bold()); Spacer(); Button(t("Refresh Docker", "Làm mới Docker")) { model.refreshDocker() }.disabled(model.busy) }; Text(t("Docker cleanup deletes directly and never uses Trash. Each level has its own confirmation.", "Dọn Docker xoá trực tiếp, không dùng Thùng rác. Mỗi mức cần xác nhận riêng.")).foregroundStyle(.secondary); if let report = model.docker { Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) { GridRow { Text(t("Type", "Loại")); Text(t("Size", "Dung lượng")); Text("Reclaimable") }.font(.caption.bold()); ForEach(report.usage) { row in GridRow { Text(row.type); Text(row.size); Text(row.reclaimable) } } }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12)); ForEach(DockerAction.allCases) { action in VStack(alignment: .leading, spacing: 8) { HStack { Text(action.title).font(.headline); Spacer(); Button(t("Review…", "Xem trước…")) { dockerAcknowledged = false; volumePhrase = ""; pendingDocker = action } }; Text(action.warning).font(.caption).foregroundStyle(.secondary); Text("docker " + action.arguments.joined(separator: " ")).font(.system(.caption, design: .monospaced)) }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10)) } } }.padding(24) }
    }
    private func dockerConfirmation(_ action: DockerAction) -> some View {
        VStack(alignment: .leading, spacing: 16) { Label(action.title, systemImage: "exclamationmark.triangle.fill").font(.title2.bold()).foregroundStyle(.orange); Text(action.warning); if let report = model.docker { Text(t("Estimated reclaimable: ", "Ước tính reclaimable: ") + report.estimate(for: action)).font(.callout); Toggle(t("I understand this deletes directly and I have checked my data.", "Tôi hiểu thao tác xoá trực tiếp và đã kiểm tra dữ liệu."), isOn: $dockerAcknowledged); if action == .volumes { TextField(t("Type DELETE VOLUMES", "Gõ DELETE VOLUMES"), text: $volumePhrase).textFieldStyle(.roundedBorder) }; HStack { Button(t("Cancel", "Huỷ")) { pendingDocker = nil }; Spacer(); Button(t("Run prune", "Chạy prune"), role: .destructive) { pendingDocker = nil; model.prune(action, report: report) }.disabled(!dockerAcknowledged || (action == .volumes && volumePhrase != "DELETE VOLUMES")) } } }.padding(26).frame(width: 650)
    }
    private var activitySheet: some View {
        let lines = model.activity.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: model.activityTitle.contains("complete") ? "checkmark.circle.fill" : "clock.arrow.circlepath").font(.system(size: 30)).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.activityTitle).font(.title3.bold()).foregroundStyle(.white)
                    Text(model.activityDate.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.white.opacity(0.82))
                }
                Spacer()
            }.padding(22).background(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 14) {
                Label(t("Operation details", "Chi tiết thao tác"), systemImage: "list.bullet.rectangle").font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: line.hasPrefix("Moved") ? "checkmark.circle.fill" : "info.circle.fill").foregroundStyle(line.hasPrefix("Moved") ? .blue : .secondary)
                                Text(line).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(11).background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                Text(t("The list was updated without a full scan. Use Refresh when you want a new storage measurement.", "Danh sách đã được cập nhật mà không quét lại toàn bộ. Dùng Làm mới khi bạn muốn đo lại dung lượng.")).font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button(t("Done", "Xong")) { model.showActivity = false }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
            }.padding(22)
        }.frame(width: 720, height: 470).background(Color(nsColor: .windowBackgroundColor))
    }

    private var accessGuide: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(t("Deep scan & access", "Quét sâu và quyền truy cập"), systemImage: "lock.shield").font(.title2.bold()).foregroundStyle(.blue)
            Text(t("Fuk Mac Storage scans inside each selected storage category. If macOS protects some files, the app reports a partial size and requires an extra confirmation before moving the parent item to Trash.", "Fuk Mac Storage quét bên trong từng nhóm dữ liệu. Nếu macOS bảo vệ một số file, app ghi dung lượng một phần và yêu cầu xác nhận thêm trước khi chuyển mục cha vào Thùng rác."))
            Divider()
            Text(t("Deep scan", "Quét sâu")).font(.headline)
            Text(t("Off by default: Desktop, Documents and Downloads are skipped, so macOS does not ask for access. Turn it on in Settings to scan them and to add a read-only Entire disk overview. Signed builds keep the permissions you grant, so macOS asks only once.", "Mặc định tắt: Desktop, Documents và Downloads được bỏ qua nên macOS không hỏi quyền. Bật trong Cài đặt để quét các thư mục này và thêm nhóm Toàn bộ ổ đĩa (chỉ xem). Bản build đã ký giữ lại quyền bạn cấp, nên macOS chỉ hỏi một lần."))
            Divider()
            Text(t("How to clean all app cache", "Cách dọn toàn bộ app cache")).font(.headline)
            Text(t("Scan → App caches → Select all scanned → Clean selected. This moves the contents of your Caches folder to Trash; it does not delete the Caches folder itself.", "Quét → App caches → Chọn tất cả đã quét → Dọn mục đã chọn. App chuyển nội dung của Caches vào Thùng rác, không xoá thư mục Caches."))
            Divider()
            Text(t("Full Disk Access", "Full Disk Access")).font(.headline)
            Text(t("If Terminal can remove an item but this app cannot, Terminal may have Full Disk Access. You can grant the same permission in System Settings → Privacy & Security → Full Disk Access, then quit and reopen Fuk Mac Storage and scan again.", "Nếu Terminal xoá được mà app không được, Terminal có thể đã có Full Disk Access. Bạn có thể cấp quyền đó tại System Settings → Privacy & Security → Full Disk Access, sau đó tắt/mở Fuk Mac Storage và quét lại."))
            Text(t("Risk: Full Disk Access lets this app inspect and move much more of your personal data. Only enable it when necessary, use the signed copy you trust, and turn it off again when you are done. It does not bypass macOS protections for every system-owned file.", "Rủi ro: Full Disk Access cho phép app xem và chuyển nhiều dữ liệu cá nhân hơn. Chỉ bật khi cần, chỉ dùng bản app bạn tin cậy và tắt lại sau khi xong. Quyền này không vượt qua mọi bảo vệ của macOS đối với file hệ thống."))
                .foregroundStyle(.orange)
            HStack { Spacer(); Button(t("Close", "Đóng")) { showAccessGuide = false }.keyboardShortcut(.cancelAction) }
        }.padding(26).frame(width: 690)
    }
}

private struct MetricCard<Footer: View>: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color
    @ViewBuilder let footer: () -> Footer
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
            footer()
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct EntryRow: View {
    let entry: DiskEntry
    let fraction: Double
    let selected: Bool
    let opening: Bool
    let disabled: Bool
    let t: (String, String) -> String
    let toggle: () -> Void
    let open: () -> Void
    let reveal: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if entry.eligible {
                    Toggle("", isOn: Binding(get: { selected }, set: { _ in toggle() })).labelsHidden().toggleStyle(.checkbox).disabled(disabled)
                } else {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help(t("Protected — cannot be cleaned", "Được bảo vệ — không thể dọn"))
                }
            }.frame(width: 20)
            Image(systemName: entry.isLink ? "link" : (entry.isDirectory ? "folder.fill" : "doc.fill"))
                .foregroundStyle(entry.isDirectory ? Color.blue.opacity(0.85) : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.url.lastPathComponent).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                let tags = badges
                if !tags.isEmpty {
                    HStack(spacing: 5) { ForEach(tags, id: \.0) { tag in Text(tag.0).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1.5).foregroundStyle(tag.1).background(tag.1.opacity(0.12), in: Capsule()) } }
                }
            }
            Spacer(minLength: 12)
            ProgressView(value: min(max(fraction, 0.02), 1)).tint(selected ? .blue : .secondary).frame(width: 90)
            Text(formattedBytes(entry.bytes)).font(.callout.weight(.medium)).monospacedDigit().frame(width: 76, alignment: .trailing)
            HStack(spacing: 4) {
                RowIconButton(systemImage: "folder", help: t("Show in Finder", "Hiện trong Finder"), action: reveal)
                if opening { ProgressView().controlSize(.small).frame(width: 32, height: 32) }
                else if entry.isDirectory { RowIconButton(systemImage: "chevron.right", help: t("Open folder", "Mở thư mục"), prominent: true, action: open).disabled(disabled) }
                else { Color.clear.frame(width: 32, height: 32) }
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected || opening ? Color.blue.opacity(0.10) : (hovering ? Color.primary.opacity(0.04) : .clear)).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if entry.isDirectory && !disabled { open() } }
        .onTapGesture { if entry.eligible && !disabled { toggle() } }
        .help(entry.url.path)
    }
    private var badges: [(String, Color)] {
        var tags: [(String, Color)] = []
        if entry.needsExtraConfirmation { tags.append((t("Extra confirmation", "Cần xác nhận thêm"), .orange)) }
        if entry.issueCount > 0 { tags.append((t("Partial scan", "Quét một phần"), .orange)) }
        if entry.isLink { tags.append((t("Symlink — not followed", "Symlink — không đi theo"), .secondary)) }
        return tags
    }
}

/// Row action with a 32×32 hit area and a hover highlight, so it is easy to click.
private struct RowIconButton: View {
    let systemImage: String
    let help: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(prominent ? Color.blue : Color.secondary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(hovering && isEnabled ? Color.primary.opacity(0.10) : (prominent ? Color.blue.opacity(0.10) : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}
