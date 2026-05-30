//
//  GwaTopAcademicForms.swift
//  GwaTop
//
//  학기/과목 추가·수정 폼 — NavigationLink로 push되도록 NavigationStack 의존성 없음.
//  같은 navigation context에서 push되기 때문에 시트 스택 없이 자연스러운 뒤로가기로 흐름.
//

import SwiftUI

// MARK: - 학기 폼 (push view 형태)

/// 학기 종류 — 정규학기(1·2학기) + 계절학기(여름·겨울).
/// 선택하면 연도와 함께 이름·기간을 자동으로 채운다 (사용자가 아래에서 수정 가능).
enum GwaTopSemesterTerm: String, CaseIterable, Identifiable {
    case spring, summer, fall, winter
    var id: String { rawValue }
    var label: String {
        switch self {
        case .spring: return "1학기"
        case .summer: return "여름"
        case .fall:   return "2학기"
        case .winter: return "겨울"
        }
    }
    func name(year: Int) -> String {
        switch self {
        case .spring: return "\(year)-1학기"
        case .fall:   return "\(year)-2학기"
        case .summer: return "\(year) 여름 계절학기"
        case .winter: return "\(year) 겨울 계절학기"
        }
    }
    private var startMD: (Int, Int) {
        switch self {
        case .spring: return (3, 1)
        case .summer: return (7, 1)
        case .fall:   return (9, 1)
        case .winter: return (1, 1)
        }
    }
    private var endMD: (Int, Int) {
        switch self {
        case .spring: return (6, 30)
        case .summer: return (8, 31)
        case .fall:   return (12, 31)
        case .winter: return (2, 28)
        }
    }
    func startDate(year: Int) -> Date { Self.makeDate(year, startMD.0, startMD.1) }
    func endDate(year: Int) -> Date { Self.makeDate(year, endMD.0, endMD.1) }

    private static func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar.current.date(from: c) ?? Date()
    }
    /// 오늘 월 기준 기본 학기 종류.
    static var current: GwaTopSemesterTerm {
        switch Calendar.current.component(.month, from: Date()) {
        case 3...6:  return .spring
        case 9...12: return .fall
        case 7...8:  return .summer
        default:     return .winter
        }
    }
}

struct GwaTopNewSemesterFormView: View {
    var onCreated: (GwaTopSemesterDTO) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var term: GwaTopSemesterTerm = .current
    @State private var year: Int = Calendar.current.component(.year, from: Date())
    @State private var name: String = defaultSemesterName()
    @State private var startDate: Date = defaultStartDate()
    @State private var endDate: Date = defaultEndDate()
    @State private var isActive: Bool = true

    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String? = nil

    /// 선택 가능한 연도 — 작년 ~ 내후년.
    private var yearOptions: [Int] {
        let y = Calendar.current.component(.year, from: Date())
        return [y - 1, y, y + 1, y + 2]
    }

    var body: some View {
        Form {
            Section("학기 종류") {
                Picker("학기", selection: $term) {
                    ForEach(GwaTopSemesterTerm.allCases) { t in
                        Text(t.label).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                Picker("연도", selection: $year) {
                    ForEach(yearOptions, id: \.self) { y in
                        Text("\(y)년").tag(y)
                    }
                }
            }
            Section("이름") {
                TextField("예: 2026-1학기", text: $name)
            }
            Section("기간") {
                DatePicker("시작일", selection: $startDate, displayedComponents: .date)
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                DatePicker("종료일", selection: $endDate, in: startDate..., displayedComponents: .date)
                    .environment(\.locale, Locale(identifier: "ko_KR"))
            }
            Section {
                Toggle("현재 학기로 설정", isOn: $isActive)
            } footer: {
                Text("켜면 기존에 활성인 학기는 자동으로 비활성으로 바뀝니다.")
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(GwaTopHomeTheme.warning) }
            }

            Section {
                Button(action: submit) {
                    HStack {
                        if isSubmitting { ProgressView().padding(.trailing, 6) }
                        Text(isSubmitting ? "등록 중…" : "등록하기")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.heavy)
                    }
                }
                .disabled(!canSubmit)
            }
        }
        .navigationTitle("새 학기")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: term) { _, _ in applyTermPreset() }
        .onChange(of: year) { _, _ in applyTermPreset() }
    }

    /// 학기 종류·연도 선택을 이름/기간에 반영. 사용자가 그 뒤 직접 수정 가능.
    private func applyTermPreset() {
        name = term.name(year: year)
        startDate = term.startDate(year: year)
        endDate = term.endDate(year: year)
    }

    private var canSubmit: Bool {
        !isSubmitting &&
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        endDate > startDate
    }

    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        Task {
            await MainActor.run { isSubmitting = true; errorMessage = nil }
            do {
                let newSem = try await GwaTopSemesterService.shared.create(
                    name: trimmedName,
                    startDate: startDate,
                    endDate: endDate,
                    isActive: isActive
                )
                await MainActor.run {
                    onCreated(newSem)
                    dismiss()
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    errorMessage = "등록 실패: \(msg)"
                    isSubmitting = false
                }
            }
        }
    }
}


// MARK: - 과목 폼 (create + edit 통합, push view 형태)

enum GwaTopCourseFormMode {
    case create
    case edit(GwaTopCourseDTO)
}

// 과목 카드용 파스텔 팔레트.
// 진행률 바·아이콘·% 텍스트에 그대로 쓰여도 충분히 가독성 있는 명도(약 70%)로 맞췄다.
// 인덱스 0이 기본색이며, 모든 fallback("#4F8EF7", "#3B82F6") 도 이 값으로 매핑된다.
let GwaTopCourseColorPalette: [String] = [
    "#8AB6F0", "#B5A0F0", "#F5B587", "#88D4B0",
    "#F0A8A8", "#F0CC7E", "#F0A8CC", "#88D0DC",
]

let GwaTopDefaultCourseColor: String = GwaTopCourseColorPalette[0]  // #8AB6F0

/// 구버전(원색) hex → 파스텔 hex 리매핑 테이블.
/// 이미 DB에 저장된 과목도 클라이언트에서 파스텔로 보이도록 변환 시점에 끼워 넣는다.
let GwaTopVividToPastel: [String: String] = [
    "#3B82F6": "#8AB6F0",   // blue-500   → pastel sky
    "#8B5CF6": "#B5A0F0",   // violet-500 → lavender
    "#F97316": "#F5B587",   // orange-500 → peach
    "#10B981": "#88D4B0",   // emerald-500→ mint
    "#EF4444": "#F0A8A8",   // red-500    → coral
    "#F59E0B": "#F0CC7E",   // amber-500  → buttercream
    "#EC4899": "#F0A8CC",   // pink-500   → soft rose
    "#06B6D4": "#88D0DC",   // cyan-500   → aqua
    "#4F8EF7": "#8AB6F0",   // legacy default → pastel sky
]

struct GwaTopCourseFormView: View {
    let mode: GwaTopCourseFormMode
    var defaultSemesterId: String? = nil
    var onSaved: (GwaTopCourseDTO) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var semesters: [GwaTopSemesterDTO] = []
    @State private var selectedSemesterId: String? = nil
    @State private var name: String = ""
    @State private var professor: String = ""
    @State private var color: String = GwaTopDefaultCourseColor

    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isLoading: Bool = false

    private var isEdit: Bool {
        if case .edit = mode { return true } else { return false }
    }

    var body: some View {
        Form {
            // 학기 — create 모드 + 학기가 여럿일 때만 노출
            if case .create = mode {
                Section("학기") {
                    if isLoading && semesters.isEmpty {
                        HStack { ProgressView(); Text("불러오는 중…") }
                    } else if semesters.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("등록된 학기가 없습니다.")
                                .font(.gwaTopSystem(size: 14, weight: .heavy))
                            Text("아래 ‘새 학기 추가’로 먼저 만드세요.")
                                .font(.gwaTopSystem(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("학기 선택", selection: Binding(
                            get: { selectedSemesterId ?? semesters.first?.id ?? "" },
                            set: { selectedSemesterId = $0 }
                        )) {
                            ForEach(semesters) { s in
                                Text(s.isActive ? "\(s.name) (활성)" : s.name).tag(s.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    NavigationLink {
                        GwaTopNewSemesterFormView { newSem in
                            // 새 학기를 학기 목록에 추가하고 자동 선택
                            if !semesters.contains(where: { $0.id == newSem.id }) {
                                semesters.insert(newSem, at: 0)
                            }
                            selectedSemesterId = newSem.id
                        }
                    } label: {
                        Label("새 학기 추가", systemImage: "plus.circle.fill")
                            .foregroundStyle(GwaTopHomeTheme.primary)
                            .fontWeight(.heavy)
                    }
                }
            }

            Section("기본 정보") {
                TextField("과목명 (예: 데이터베이스)", text: $name)
                    .textInputAutocapitalization(.never)
                TextField("담당 교수 (선택)", text: $professor)
            }

            Section("색상") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(GwaTopCourseColorPalette, id: \.self) { hex in
                            Circle()
                                .fill(Color.gwaTopHex(hex))
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Circle()
                                        .stroke(color == hex ? GwaTopHomeTheme.textPrimary.opacity(0.6) : Color.clear, lineWidth: 3)
                                )
                                .onTapGesture { color = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(GwaTopHomeTheme.warning) }
            }

            Section {
                Button(action: submit) {
                    HStack {
                        if isSubmitting { ProgressView().padding(.trailing, 6) }
                        Text(submitTitle)
                            .frame(maxWidth: .infinity)
                            .fontWeight(.heavy)
                    }
                }
                .disabled(!canSubmit)
            }
        }
        .navigationTitle(isEdit ? "과목 수정" : "새 과목")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadInitial() }
    }

    private var submitTitle: String {
        if isSubmitting { return isEdit ? "저장 중…" : "추가 중…" }
        return isEdit ? "저장" : "추가"
    }

    private var canSubmit: Bool {
        !isSubmitting &&
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (isEdit || selectedSemesterId != nil)
    }

    private func loadInitial() async {
        switch mode {
        case .create:
            await MainActor.run { isLoading = true }
            do {
                let list = try await GwaTopSemesterService.shared.fetchAll()
                await MainActor.run {
                    self.semesters = list
                    self.selectedSemesterId = defaultSemesterId
                        ?? list.first(where: { $0.isActive })?.id
                        ?? list.first?.id
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { errorMessage = msg }
            }
            await MainActor.run { isLoading = false }
        case .edit(let course):
            await MainActor.run {
                self.name = course.name
                self.professor = course.professor ?? ""
                self.color = course.color ?? GwaTopDefaultCourseColor
                self.selectedSemesterId = course.semesterId
            }
        }
    }

    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedProf = professor.trimmingCharacters(in: .whitespaces)
        let profOrNil: String? = trimmedProf.isEmpty ? nil : trimmedProf

        Task {
            await MainActor.run { isSubmitting = true; errorMessage = nil }
            do {
                let saved: GwaTopCourseDTO
                switch mode {
                case .create:
                    guard let semId = selectedSemesterId else {
                        await MainActor.run {
                            errorMessage = "학기를 선택해주세요."
                            isSubmitting = false
                        }
                        return
                    }
                    saved = try await GwaTopCourseService.shared.create(
                        semesterId: semId,
                        name: trimmedName,
                        professor: profOrNil,
                        color: color
                    )
                case .edit(let course):
                    saved = try await GwaTopCourseService.shared.update(
                        id: course.id,
                        name: trimmedName,
                        professor: profOrNil,
                        color: color
                    )
                }
                await MainActor.run {
                    onSaved(saved)
                    dismiss()
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    errorMessage = "저장 실패: \(msg)"
                    isSubmitting = false
                }
            }
        }
    }
}


// MARK: - Defaults

private func defaultSemesterName() -> String {
    let cal = Calendar.current
    let m = cal.component(.month, from: Date())
    let y = cal.component(.year, from: Date())
    switch m {
    case 3...6:   return "\(y)-1학기"
    case 9...12:  return "\(y)-2학기"
    case 7...8:   return "\(y) 여름 계절학기"
    default:      return "\(y) 겨울 계절학기"
    }
}

private func defaultStartDate() -> Date {
    let cal = Calendar.current
    var c = cal.dateComponents([.year, .month], from: Date())
    c.day = 1
    return cal.date(from: c) ?? Date()
}

private func defaultEndDate() -> Date {
    Calendar.current.date(byAdding: .month, value: 4, to: defaultStartDate()) ?? Date()
}
