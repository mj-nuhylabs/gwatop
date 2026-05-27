//
//  GwaTopAcademicForms.swift
//  GwaTop
//
//  학기/과목 추가·수정 폼 — NavigationLink로 push되도록 NavigationStack 의존성 없음.
//  같은 navigation context에서 push되기 때문에 시트 스택 없이 자연스러운 뒤로가기로 흐름.
//

import SwiftUI

// MARK: - 학기 폼 (push view 형태)

struct GwaTopNewSemesterFormView: View {
    var onCreated: (GwaTopSemesterDTO) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = defaultSemesterName()
    @State private var startDate: Date = defaultStartDate()
    @State private var endDate: Date = defaultEndDate()
    @State private var isActive: Bool = true

    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        Form {
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

let GwaTopCourseColorPalette: [String] = [
    "#3B82F6", "#8B5CF6", "#F97316", "#10B981",
    "#EF4444", "#F59E0B", "#EC4899", "#06B6D4",
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
    @State private var color: String = "#3B82F6"

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
                                        .stroke(color == hex ? Color.black.opacity(0.6) : Color.clear, lineWidth: 3)
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
                self.color = course.color ?? "#3B82F6"
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
