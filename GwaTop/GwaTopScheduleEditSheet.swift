//
//  GwaTopScheduleEditSheet.swift
//  GwaTop
//
//  일정 수동 추가 / 수정 시트.
//  - mode = .create  → POST /v1/schedules
//  - mode = .edit    → PUT /v1/schedules/{id}
//

import SwiftUI

enum GwaTopScheduleEditMode {
    case create
    case edit(GwaTopCalendarEvent)
}

struct GwaTopScheduleEditSheet: View {
    let mode: GwaTopScheduleEditMode
    var initialDate: Date? = nil           // create 모드에서 캘린더가 선택한 날짜
    var onSaved: () -> Void                // 저장 성공 시 부모가 reload 트리거

    @Environment(\.dismiss) private var dismiss

    @State private var courses: [GwaTopCourseDTO] = []
    @State private var selectedCourseId: String? = nil

    @State private var title: String = ""
    @State private var eventType: GwaTopCalendarEventType = .assignment
    @State private var date: Date = Date()
    @State private var description: String = ""

    @State private var isLoadingCourses: Bool = false
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String? = nil

    private var isEditMode: Bool {
        if case .edit = mode { return true } else { return false }
    }

    private var navigationTitle: String {
        isEditMode ? "일정 수정" : "새 일정 추가"
    }

    private var submitButtonTitle: String {
        if isSubmitting { return isEditMode ? "저장 중…" : "추가 중…" }
        return isEditMode ? "저장하기" : "추가하기"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        label("과목")
                        if isLoadingCourses {
                            HStack { ProgressView(); Text("불러오는 중…").font(.system(size: 13)) }
                        } else if courses.isEmpty {
                            Text("과목이 없습니다. 강의계획서 업로드 화면에서 먼저 과목을 등록하세요.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            Picker("과목", selection: Binding(
                                get: { selectedCourseId ?? courses.first?.id ?? "" },
                                set: { selectedCourseId = $0 }
                            )) {
                                ForEach(courses) { c in
                                    HStack {
                                        Circle()
                                            .fill(Color.gwaTopHex(c.color ?? "#4F8EF7"))
                                            .frame(width: 10, height: 10)
                                        Text(c.name)
                                    }
                                    .tag(c.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        label("제목")
                        TextField("예: 중간고사, 보고서 제출", text: $title)
                            .padding(14)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        label("종류")
                        Picker("종류", selection: $eventType) {
                            Text("강의").tag(GwaTopCalendarEventType.lecture)
                            Text("과제").tag(GwaTopCalendarEventType.assignment)
                            Text("시험").tag(GwaTopCalendarEventType.exam)
                            Text("회의").tag(GwaTopCalendarEventType.meeting)
                            Text("기타").tag(GwaTopCalendarEventType.upload)
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        label("날짜 / 시간")
                        DatePicker("", selection: $date,
                                   displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .environment(\.locale, Locale(identifier: "ko_KR"))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        label("메모 (선택)")
                        TextEditor(text: $description)
                            .frame(minHeight: 90)
                            .padding(8)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if let msg = errorMessage {
                        Text(msg)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.orange)
                    }

                    Button(action: submit) {
                        HStack {
                            if isSubmitting { ProgressView().tint(.white).padding(.trailing, 6) }
                            Text(submitButtonTitle)
                                .font(.system(size: 16, weight: .heavy))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canSubmit ? GwaTopHomeTheme.primary : Color.gray.opacity(0.4))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(!canSubmit)
                }
                .padding(20)
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("취소") { dismiss() }
                }
            }
            .task {
                await loadCourses()
                applyInitialValues()
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .heavy))
            .foregroundStyle(GwaTopHomeTheme.textPrimary)
    }

    private var canSubmit: Bool {
        !isSubmitting &&
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        selectedCourseId != nil
    }

    private func applyInitialValues() {
        switch mode {
        case .create:
            if let d = initialDate { date = d }
        case .edit(let event):
            title = event.title
            eventType = event.eventType
            date = event.startDate
            description = event.memo
            selectedCourseId = event.course.id
        }
    }

    private func loadCourses() async {
        await MainActor.run { self.isLoadingCourses = true }
        do {
            let list = try await GwaTopCourseService.shared.fetchAll()
            await MainActor.run {
                self.courses = list
                if self.selectedCourseId == nil {
                    self.selectedCourseId = list.first?.id
                }
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await MainActor.run { self.errorMessage = msg }
        }
        await MainActor.run { self.isLoadingCourses = false }
    }

    private func submit() {
        guard let courseId = selectedCourseId else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedDesc = description.trimmingCharacters(in: .whitespaces)
        let descOrNil: String? = trimmedDesc.isEmpty ? nil : trimmedDesc

        Task {
            await MainActor.run {
                self.isSubmitting = true
                self.errorMessage = nil
            }
            do {
                switch mode {
                case .create:
                    _ = try await GwaTopScheduleService.shared.create(
                        courseId: courseId,
                        title: trimmedTitle,
                        type: typeString(eventType),
                        dueDate: date,
                        description: descOrNil
                    )
                case .edit(let event):
                    _ = try await GwaTopScheduleService.shared.update(
                        id: event.id,
                        courseId: courseId,
                        title: trimmedTitle,
                        type: typeString(eventType),
                        dueDate: date,
                        description: descOrNil
                    )
                }
                await MainActor.run {
                    onSaved()
                    dismiss()
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    self.errorMessage = "저장 실패: \(msg)"
                    self.isSubmitting = false
                }
            }
        }
    }

    private func typeString(_ t: GwaTopCalendarEventType) -> String {
        switch t {
        case .lecture:    return "lecture"
        case .assignment: return "assignment"
        case .exam:       return "exam"
        case .meeting:    return "meeting"
        case .upload:     return "upload"
        }
    }
}
