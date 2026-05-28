//
//  GwaTopAdminView.swift
//  GwaTop
//
//  출시 전 테스트용 관리자 탭.
//  4개 섹션(개요 / 사용자 / 파일 / 일정)을 segmented 로 전환하고,
//  사용자 한 명을 탭하면 그 사용자의 전체 트리를 시트로 보여준다.
//

import SwiftUI

struct GwaTopAdminView: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview, users, files, schedules
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overview:  return "개요"
            case .users:     return "사용자"
            case .files:     return "파일"
            case .schedules: return "일정"
            }
        }
    }

    @State private var section: Section = .overview

    @State private var overview: GwaTopAdminOverview? = nil
    @State private var users: [GwaTopAdminUserBrief] = []
    @State private var files: [GwaTopAdminFile] = []
    @State private var schedules: [GwaTopAdminSchedule] = []

    @State private var selectedUser: GwaTopAdminUserBrief? = nil
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    GwaTopScreenHeader(title: "관리자") {
                        Button {
                            Task { await reload() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.gwaTopSystem(size: 15, weight: .bold))
                                .foregroundStyle(GwaTopHomeTheme.primary)
                                .frame(width: 38, height: 38)
                                .background(GwaTopHomeTheme.surface)
                                .clipShape(Circle())
                        }
                    }

                    ScrollView {
                        VStack(spacing: 14) {
                            sectionPicker

                            if let errorMessage {
                                errorBanner(errorMessage)
                            }

                            if isLoading {
                                loadingState
                            } else {
                                content
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await reload() }
            .sheet(item: $selectedUser) { user in
                GwaTopAdminUserDetailSheet(user: user)
                    .presentationDetents([.large])
            }
        }
    }

    // MARK: - Picker

    private var sectionPicker: some View {
        Picker("", selection: $section) {
            ForEach(Section.allCases) { s in
                Text(s.label).tag(s)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Content per section

    @ViewBuilder
    private var content: some View {
        switch section {
        case .overview:
            overviewContent
        case .users:
            usersContent
        case .files:
            filesContent
        case .schedules:
            schedulesContent
        }
    }

    private var overviewContent: some View {
        VStack(spacing: 12) {
            if let ov = overview {
                statGrid(ov.counts)
                statusBreakdown(ov.fileStatus)
            } else {
                Text("개요 데이터가 없어요.")
                    .font(.gwaTopSystem(size: 13))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .padding(.vertical, 24)
            }
        }
    }

    private func statGrid(_ counts: [String: Int]) -> some View {
        let items: [(String, String)] = [
            ("users", "사용자"),
            ("semesters", "학기"),
            ("courses", "과목"),
            ("files", "파일"),
            ("schedules", "일정"),
            ("todos", "할 일"),
            ("devices", "디바이스"),
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(items, id: \.0) { key, label in
                statCell(label: label, value: counts[key] ?? 0)
            }
        }
    }

    private func statCell(label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.gwaTopSystem(size: 12, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
            Text("\(value)")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(GwaTopHomeTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statusBreakdown(_ map: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("파일 상태 분포")
                .font(.gwaTopSystem(size: 13, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
            VStack(spacing: 0) {
                ForEach(Array(map.sorted { $0.key < $1.key }), id: \.key) { k, v in
                    HStack {
                        Text(k)
                            .font(.gwaTopSystem(size: 13, weight: .medium))
                        Spacer()
                        Text("\(v)")
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if k != map.keys.sorted().last { Divider().padding(.leading, 14) }
                }
            }
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.top, 6)
    }

    private var usersContent: some View {
        VStack(spacing: 0) {
            if users.isEmpty {
                emptyText("등록된 사용자가 없어요.")
            } else {
                ForEach(Array(users.enumerated()), id: \.element.id) { i, u in
                    Button { selectedUser = u } label: { userRow(u) }
                        .buttonStyle(.plain)
                    if i < users.count - 1 { Divider().padding(.leading, 16) }
                }
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func userRow(_ u: GwaTopAdminUserBrief) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(u.provider == "google" ? GwaTopHomeTheme.danger.opacity(0.18) : GwaTopHomeTheme.primary.opacity(0.18))
                .frame(width: 32, height: 32)
                .overlay(
                    Text(String(u.name.prefix(1)).uppercased())
                        .font(.gwaTopSystem(size: 13, weight: .heavy))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(u.name.isEmpty ? "(이름 없음)" : u.name)
                    .font(.gwaTopSystem(size: 14, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                Text("\(u.email) · \(u.provider)")
                    .font(.gwaTopSystem(size: 11, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.gwaTopSystem(size: 11, weight: .semibold))
                .foregroundStyle(Color.gray.opacity(0.4))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var filesContent: some View {
        VStack(spacing: 0) {
            if files.isEmpty {
                emptyText("파일이 없어요.")
            } else {
                ForEach(Array(files.enumerated()), id: \.element.id) { i, f in
                    fileRow(f)
                    if i < files.count - 1 { Divider().padding(.leading, 16) }
                }
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func fileRow(_ f: GwaTopAdminFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if f.isSyllabus {
                    Text("SYL")
                        .font(.gwaTopSystem(size: 9, weight: .heavy))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(GwaTopHomeTheme.primary.opacity(0.15))
                        .foregroundStyle(GwaTopHomeTheme.primary)
                        .clipShape(Capsule())
                }
                Text(f.filename)
                    .font(.gwaTopSystem(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(statusText(f))
                    .font(.gwaTopSystem(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor(f.status))
            }
            Text("\(f.userEmail ?? "-") · \(f.courseName ?? "(과목 없음)")")
                .font(.gwaTopSystem(size: 11, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func statusText(_ f: GwaTopAdminFile) -> String {
        if let w = f.week { return "\(f.status) · \(w)주차" }
        return f.status
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "classified", "parsed":              return GwaTopHomeTheme.success
        case "classifying", "parsing",
             "processing", "extracting":         return GwaTopHomeTheme.warning
        case "failed":                            return GwaTopHomeTheme.danger
        case "unclassified":                      return .gray
        default:                                  return GwaTopHomeTheme.textSecondary
        }
    }

    private var schedulesContent: some View {
        VStack(spacing: 0) {
            if schedules.isEmpty {
                emptyText("일정이 없어요.")
            } else {
                ForEach(Array(schedules.enumerated()), id: \.element.id) { i, s in
                    scheduleRow(s)
                    if i < schedules.count - 1 { Divider().padding(.leading, 16) }
                }
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func scheduleRow(_ s: GwaTopAdminSchedule) -> some View {
        HStack(spacing: 10) {
            Text(s.type)
                .font(.gwaTopSystem(size: 9, weight: .heavy))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(GwaTopHomeTheme.primary.opacity(0.12))
                .foregroundStyle(GwaTopHomeTheme.primary)
                .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title)
                    .font(.gwaTopSystem(size: 13, weight: .semibold))
                Text("\(s.userEmail ?? "-") · \(s.courseName ?? "-") · \(formatDate(s.dueDate))")
                    .font(.gwaTopSystem(size: 11, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if s.isAuto {
                Image(systemName: "sparkles")
                    .font(.gwaTopSystem(size: 10, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    // MARK: - States

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("불러오는 중…")
                .font(.gwaTopSystem(size: 13, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private func emptyText(_ msg: String) -> some View {
        Text(msg)
            .font(.gwaTopSystem(size: 13, weight: .medium))
            .foregroundStyle(GwaTopHomeTheme.textSecondary)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GwaTopHomeTheme.danger)
            Text(msg)
                .font(.gwaTopSystem(size: 12, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GwaTopHomeTheme.danger.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Actions

    @MainActor
    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let ovTask = GwaTopAdminService.shared.fetchOverview()
            async let usersTask = GwaTopAdminService.shared.fetchUsers()
            async let filesTask = GwaTopAdminService.shared.fetchAllFiles()
            async let schedulesTask = GwaTopAdminService.shared.fetchAllSchedules()

            overview = try await ovTask
            users = try await usersTask
            files = try await filesTask
            schedules = try await schedulesTask
        } catch {
            errorMessage = "관리자 데이터를 불러오지 못했어요: \(error.localizedDescription)"
        }
    }

    private func formatDate(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ko_KR")
        fmt.dateFormat = "M/d HH:mm"
        return fmt.string(from: d)
    }
}

// MARK: - 사용자 상세 시트

struct GwaTopAdminUserDetailSheet: View {
    let user: GwaTopAdminUserBrief

    @Environment(\.dismiss) private var dismiss
    @State private var detail: GwaTopAdminUserDetail? = nil
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    // 위험 작업 상태
    @State private var pendingDestructive: DestructiveAction? = nil
    @State private var deletingFileId: String? = nil
    @State private var resultMessage: String? = nil

    enum DestructiveAction: Identifiable {
        case syllabusReset
        case fullReset
        case deleteFile(file: GwaTopAdminFile)

        var id: String {
            switch self {
            case .syllabusReset:        return "syllabus-reset"
            case .fullReset:            return "full-reset"
            case .deleteFile(let f):    return "delete-\(f.id)"
            }
        }

        var title: String {
            switch self {
            case .syllabusReset:        return "강의계획서 데이터 리셋"
            case .fullReset:            return "전체 학습 데이터 리셋"
            case .deleteFile(let f):    return "파일 삭제: \(f.filename)"
            }
        }

        var description: String {
            switch self {
            case .syllabusReset:
                return "강의계획서 파일과 그로부터 자동 생성된 일정/할 일을 삭제하고 과목의 시간표/주차 메타를 비웁니다. 사용자가 직접 만든 일정/할 일은 유지돼요."
            case .fullReset:
                return "이 사용자의 모든 파일/일정/할 일을 삭제합니다. 학기/과목/계정 자체는 유지돼요. 되돌릴 수 없어요."
            case .deleteFile:
                return "이 파일 하나만 DB에서 제거합니다. 강의계획서면 거기서 만든 auto 일정/할 일도 함께 정리돼요."
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        userHeader

                        if isLoading {
                            ProgressView().padding(.top, 40)
                                .frame(maxWidth: .infinity)
                        } else if let err = errorMessage {
                            Text(err)
                                .font(.gwaTopSystem(size: 12, weight: .semibold))
                                .foregroundStyle(GwaTopHomeTheme.danger)
                        } else if let d = detail {
                            countsCard(d)
                            section(title: "학기") {
                                ForEach(d.semesters) { s in
                                    HStack {
                                        Text(s.name).font(.gwaTopSystem(size: 13, weight: .semibold))
                                        Spacer()
                                        Text("\(s.startDate) ~ \(s.endDate)")
                                            .font(.gwaTopSystem(size: 11))
                                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                                        if s.isActive {
                                            Text("active")
                                                .font(.gwaTopSystem(size: 10, weight: .bold))
                                                .foregroundStyle(GwaTopHomeTheme.success)
                                        }
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                }
                            }
                            section(title: "과목") {
                                ForEach(d.courses) { c in
                                    HStack {
                                        Circle().fill(c.color.map(Color.gwaTopHex) ?? .gray)
                                            .frame(width: 8, height: 8)
                                        Text(c.name).font(.gwaTopSystem(size: 13, weight: .semibold))
                                        Spacer()
                                        Text("files \(c.fileCount) · sched \(c.scheduleCount)")
                                            .font(.gwaTopSystem(size: 11))
                                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                }
                            }
                            section(title: "파일") {
                                ForEach(d.files) { f in
                                    HStack(spacing: 8) {
                                        Text(f.filename).font(.gwaTopSystem(size: 12, weight: .semibold))
                                            .lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text("\(f.status)\(f.week.map { " · \($0)w" } ?? "")")
                                            .font(.gwaTopSystem(size: 10, weight: .semibold))
                                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                                        Button(role: .destructive) {
                                            pendingDestructive = .deleteFile(file: f)
                                        } label: {
                                            if deletingFileId == f.id {
                                                ProgressView().scaleEffect(0.7)
                                            } else {
                                                Image(systemName: "trash")
                                                    .font(.gwaTopSystem(size: 12, weight: .semibold))
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(GwaTopHomeTheme.danger)
                                        .disabled(deletingFileId != nil)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                }
                            }
                            section(title: "일정") {
                                ForEach(d.schedules) { s in
                                    HStack {
                                        Text(s.title).font(.gwaTopSystem(size: 12, weight: .semibold))
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(s.type) · \(shortDate(s.dueDate))")
                                            .font(.gwaTopSystem(size: 10))
                                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                }
                            }
                            section(title: "할 일") {
                                ForEach(d.todos) { t in
                                    HStack {
                                        Image(systemName: t.isDone ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(t.isDone ? GwaTopHomeTheme.success : .gray)
                                            .font(.gwaTopSystem(size: 12))
                                        Text(t.title).font(.gwaTopSystem(size: 12, weight: .semibold))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(shortDate(t.dueDate))
                                            .font(.gwaTopSystem(size: 10))
                                            .foregroundStyle(GwaTopHomeTheme.textSecondary)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                }
                            }
                            if !d.devices.isEmpty {
                                section(title: "디바이스") {
                                    ForEach(d.devices) { dev in
                                        HStack {
                                            Image(systemName: "iphone").foregroundStyle(GwaTopHomeTheme.primary)
                                            Text(dev.platform).font(.gwaTopSystem(size: 12))
                                            Spacer()
                                            Text(dev.apnsTokenPreview)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                    }
                                }
                            }

                            if let msg = resultMessage {
                                resultBanner(msg)
                            }

                            dangerZone
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle(user.name.isEmpty ? user.email : user.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
            .task { await load() }
            .confirmationDialog(
                pendingDestructive?.title ?? "",
                isPresented: Binding(
                    get: { pendingDestructive != nil },
                    set: { if !$0 { pendingDestructive = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDestructive
            ) { action in
                Button(action.title, role: .destructive) {
                    Task { await performDestructive(action) }
                }
                Button("취소", role: .cancel) { pendingDestructive = nil }
            } message: { action in
                Text(action.description)
            }
        }
    }

    // MARK: - 위험 영역

    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("위험 영역")
                .font(.gwaTopSystem(size: 13, weight: .heavy))
                .foregroundStyle(GwaTopHomeTheme.danger)

            VStack(spacing: 10) {
                destructiveButton(
                    label: "강의계획서 데이터 리셋",
                    subtitle: "강의계획서 파일 + 자동 일정·할 일 + 시간표 메타",
                    icon: "doc.text.magnifyingglass",
                    action: { pendingDestructive = .syllabusReset }
                )
                destructiveButton(
                    label: "전체 학습 데이터 리셋",
                    subtitle: "모든 파일·일정·할 일 삭제 (학기/과목/계정은 유지)",
                    icon: "trash.fill",
                    action: { pendingDestructive = .fullReset }
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GwaTopHomeTheme.danger.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(GwaTopHomeTheme.danger.opacity(0.18), lineWidth: 1)
        )
    }

    private func destructiveButton(label: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.gwaTopSystem(size: 14, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.danger)
                    .frame(width: 32, height: 32)
                    .background(GwaTopHomeTheme.danger.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.gwaTopSystem(size: 13, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.danger)
                    Text(subtitle)
                        .font(.gwaTopSystem(size: 11, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.gwaTopSystem(size: 10, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.danger.opacity(0.6))
            }
            .padding(12)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func resultBanner(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(GwaTopHomeTheme.success)
            Text(msg)
                .font(.gwaTopSystem(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GwaTopHomeTheme.success.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @MainActor
    private func performDestructive(_ action: DestructiveAction) async {
        pendingDestructive = nil
        resultMessage = nil
        errorMessage = nil
        do {
            switch action {
            case .syllabusReset:
                let result = try await GwaTopAdminService.shared.syllabusReset(userId: user.id)
                resultMessage = summary("강의계획서 리셋 완료", from: result)
            case .fullReset:
                let result = try await GwaTopAdminService.shared.fullReset(userId: user.id)
                resultMessage = summary("전체 리셋 완료", from: result)
            case .deleteFile(let file):
                deletingFileId = file.id
                defer { deletingFileId = nil }
                let counts = try await GwaTopAdminService.shared.deleteFile(fileId: file.id)
                let pieces = counts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " · ")
                resultMessage = "파일 삭제 완료 — \(pieces)"
            }
            // 상세 데이터 다시 불러오기
            await load(silent: true)
        } catch {
            errorMessage = "작업 실패: \(error.localizedDescription)"
        }
    }

    private func summary(_ prefix: String, from result: [String: GwaTopAdminResetValue]) -> String {
        // 카운트 필드만 정렬해서 합치기 (user_email 같은 string은 한쪽에)
        let order = ["files_deleted", "syllabus_files_deleted",
                     "schedules_deleted", "auto_schedules_deleted",
                     "todos_deleted", "auto_todos_deleted",
                     "courses_reset"]
        let parts = order.compactMap { key -> String? in
            guard let v = result[key] else { return nil }
            return "\(key)=\(v.summary)"
        }
        return "\(prefix) — \(parts.joined(separator: " · "))"
    }

    private var userHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(user.email)
                .font(.gwaTopSystem(size: 13, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
            Text("provider: \(user.provider) · active: \(user.isActive ? "yes" : "no")")
                .font(.gwaTopSystem(size: 11))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
    }

    private func countsCard(_ d: GwaTopAdminUserDetail) -> some View {
        HStack(spacing: 10) {
            count("학기", d.semesters.count)
            count("과목", d.courses.count)
            count("파일", d.files.count)
            count("일정", d.schedules.count)
            count("할일", d.todos.count)
        }
    }

    private func count(_ label: String, _ n: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.system(size: 18, weight: .heavy, design: .rounded))
            Text(label).font(.gwaTopSystem(size: 10)).foregroundStyle(GwaTopHomeTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.gwaTopSystem(size: 12, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
            VStack(spacing: 0) {
                content()
            }
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @MainActor
    private func load(silent: Bool = false) async {
        if !silent { isLoading = true }
        defer { if !silent { isLoading = false } }
        do {
            detail = try await GwaTopAdminService.shared.fetchUserDetail(userId: user.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func shortDate(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ko_KR")
        fmt.dateFormat = "M/d HH:mm"
        return fmt.string(from: d)
    }
}
