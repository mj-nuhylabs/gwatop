//
//  GwaTopTimetableSheets.swift
//  GwaTop
//
//  시간표(에브리타임 스타일) 편집 시트 2종:
//   - GwaTopTimetableCourseSheet : 시간표 블록을 탭했을 때. 과목 정보 + 시간 슬롯 리스트
//                                  를 보고 편집/삭제 가능. 저장하면 Course PUT.
//   - GwaTopTimetableAddSheet    : 시간표 + 버튼을 눌렀을 때. 기존 과목 선택(또는 새 과목
//                                  만들기) + 요일/시작/종료/(반복 종료) 입력. 저장하면 해당
//                                  과목의 schedule 배열에 새 슬롯 append.
//
//  완료 콜백 onSaved/onDeleted 가 호출되면 부모(GwaTopCalendarView 등)에서 AppDataStore
//  의 courses 를 다시 fetch 해 시간표를 갱신한다.
//

import SwiftUI

// MARK: - 공용

/// 요일 → 한국어 라벨 매핑. UI 표시용.
private let GwaTopDayLabels: [(code: String, label: String)] = [
    ("MON", "월"), ("TUE", "화"), ("WED", "수"), ("THU", "목"),
    ("FRI", "금"), ("SAT", "토"), ("SUN", "일"),
]

/// 색상 팔레트 — 새 과목 만들 때 자동 부여. 백엔드 색상 토큰과 동일.
private let GwaTopCoursePalette: [String] = [
    "#4F8EF7", "#22C55E", "#F97316", "#A855F7",
    "#EC4899", "#0EA5E9", "#EF4444", "#14B8A6",
]

/// "HH:MM" 문자열로 직렬화. Date 의 시/분만 사용.
private func gwaTopHHMM(from date: Date) -> String {
    let cal = Calendar(identifier: .gregorian)
    let h = cal.component(.hour, from: date)
    let m = cal.component(.minute, from: date)
    return String(format: "%02d:%02d", h, m)
}

/// "HH:MM" → Date (오늘 날짜 + 해당 시각). 시간 비교는 분 단위로만 의미 있음.
private func gwaTopDate(fromHHMM s: String) -> Date {
    let parts = s.split(separator: ":")
    let h = parts.count >= 1 ? Int(parts[0]) ?? 9 : 9
    let m = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
    return Calendar(identifier: .gregorian).date(
        bySettingHour: max(0, min(23, h)),
        minute: max(0, min(59, m)),
        second: 0,
        of: Date()
    ) ?? Date()
}

// MARK: - 1) 시간표 블록 탭 → 정보/수정 시트

struct GwaTopTimetableCourseSheet: View {
    /// 시트 진입 시점의 과목 스냅샷. 저장 후 onSaved 콜백을 통해 부모가 새 데이터를 받는다.
    let course: GwaTopCourseDTO

    /// 저장이 성공해서 새 DTO 가 돌아왔을 때 호출.
    var onSaved: ((GwaTopCourseDTO) -> Void)? = nil
    /// 삭제 성공 시 호출.
    var onDeleted: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var professor: String
    @State private var location: String
    @State private var color: String

    // 수업 시간 모델 — "공통 시간 + 반복 요일" 을 기본으로, 다른 시간/강의실인 요일만 예외로.
    // 저장 시에는 백엔드 포맷(요일별 슬롯 배열)으로 다시 펼친다.
    /// 공통 수업 시간(시작/종료).
    @State private var commonStart: Date
    @State private var commonEnd: Date
    /// 공통 시간으로 반복되는 요일들.
    @State private var commonDays: Set<String>
    /// 예외 — 특정 요일만 다른 시간/강의실. 각 항목은 요일 1개짜리 슬롯.
    @State private var exceptions: [GwaTopClassTimeDTO]

    @State private var isSubmitting = false
    @State private var error: String? = nil
    @State private var confirmDelete = false

    /// 저장/요일 정렬용 표준 요일 순서.
    private let dayOrder = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]

    init(course: GwaTopCourseDTO,
         onSaved: ((GwaTopCourseDTO) -> Void)? = nil,
         onDeleted: ((String) -> Void)? = nil) {
        self.course = course
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _name = State(initialValue: course.name)
        _professor = State(initialValue: course.professor ?? "")
        _location = State(initialValue: course.location ?? "")
        _color = State(initialValue: course.color ?? GwaTopCoursePalette[0])

        // 기존 슬롯을 "공통 시간 + 예외" 로 분해한다.
        let decomposed = Self.decompose(course.schedule ?? [])
        _commonStart = State(initialValue: gwaTopDate(fromHHMM: decomposed.start))
        _commonEnd = State(initialValue: gwaTopDate(fromHHMM: decomposed.end))
        _commonDays = State(initialValue: decomposed.commonDays)
        _exceptions = State(initialValue: decomposed.exceptions)
    }

    /// 요일별 슬롯 배열을 "가장 흔한 시간(=공통) + 나머지(=예외)" 로 분해.
    /// 공통 시간과 정확히 같고 슬롯 전용 강의실이 없는 요일만 공통으로 묶고,
    /// 시간이 다르거나 요일 전용 강의실이 있는 슬롯은 예외로 남긴다.
    private static func decompose(_ slots: [GwaTopClassTimeDTO]) -> (start: String, end: String, commonDays: Set<String>, exceptions: [GwaTopClassTimeDTO]) {
        guard !slots.isEmpty else { return ("09:00", "10:30", [], []) }

        // 가장 많이 등장하는 (시작-종료) 쌍을 공통 시간으로 채택.
        let groups = Dictionary(grouping: slots) { "\($0.startTime)-\($0.endTime)" }
        let commonGroup = groups.max { a, b in a.value.count < b.value.count }!.value
        let cStart = commonGroup[0].startTime
        let cEnd = commonGroup[0].endTime

        var commonDays: Set<String> = []
        var exceptions: [GwaTopClassTimeDTO] = []
        for slot in slots {
            let hasCustomRoom = (slot.location?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            if slot.startTime == cStart, slot.endTime == cEnd, !hasCustomRoom {
                commonDays.insert(slot.day)
            } else {
                exceptions.append(slot)
            }
        }
        return (cStart, cEnd, commonDays, exceptions)
    }

    /// 편집 상태(공통 + 예외)를 백엔드 포맷(요일별 슬롯 배열)으로 펼친다.
    /// 예외가 지정된 요일은 예외가 우선하고, 공통에서는 빠진다.
    private func buildSchedule() -> [GwaTopClassTimeDTO] {
        let exceptionDays = Set(exceptions.map(\.day))
        let cStart = gwaTopHHMM(from: commonStart)
        let cEnd = gwaTopHHMM(from: commonEnd)

        var result: [GwaTopClassTimeDTO] = []
        for code in dayOrder where commonDays.contains(code) && !exceptionDays.contains(code) {
            result.append(GwaTopClassTimeDTO(day: code, startTime: cStart, endTime: cEnd, location: nil))
        }
        // 예외는 요일 순서대로 뒤에 붙인다.
        for code in dayOrder {
            for ex in exceptions where ex.day == code {
                result.append(ex)
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        infoCard
                        timesCard
                        if let err = error {
                            Text(err)
                                .font(.gwaTopSystem(size: 13, weight: .semibold))
                                .foregroundStyle(GwaTopHomeTheme.danger)
                        }
                        saveButton
                        deleteButton
                    }
                    .padding(20)
                }
            }
            .navigationTitle(course.name.isEmpty ? "과목" : course.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
            }
            .confirmationDialog("정말 삭제할까요?", isPresented: $confirmDelete) {
                Button("삭제", role: .destructive) { Task { await deleteCourse() } }
                Button("취소", role: .cancel) {}
            } message: {
                Text("\(course.name)\n시간표 + 학기 내 일정/할일이 모두 삭제됩니다.")
            }
        }
    }

    // MARK: 카드들

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("과목 정보")
                .font(.gwaTopSystem(size: 13, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("과목명")
                TextField("예: 자료구조와 알고리즘", text: $name)
                    .font(.gwaTopSystem(size: 16, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(GwaTopHomeTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("교수 (선택)")
                TextField("예: 김교수", text: $professor)
                    .font(.gwaTopSystem(size: 15))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(GwaTopHomeTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("강의실 (선택)")
                TextField("예: 공학관 301호", text: $location)
                    .font(.gwaTopSystem(size: 15))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(GwaTopHomeTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("색상")
                colorPalettePicker
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GwaTopHomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var colorPalettePicker: some View {
        HStack(spacing: 10) {
            ForEach(GwaTopCoursePalette, id: \.self) { hex in
                Button {
                    color = hex
                } label: {
                    Circle()
                        .fill(Color.gwaTopHex(hex))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: color == hex ? 2 : 0)
                        )
                        .overlay(
                            Circle()
                                .stroke(GwaTopHomeTheme.textPrimary.opacity(color == hex ? 0.4 : 0), lineWidth: 1.5)
                                .padding(-3)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var timesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("수업 시간")
                .font(.gwaTopSystem(size: 13, weight: .bold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)

            // ── 공통: 반복 요일 + 한 번만 지정하는 수업 시간 ──
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("반복 요일")
                commonDayPicker
            }
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("수업 시간")
                HStack(spacing: 10) {
                    DatePicker("", selection: $commonStart, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Image(systemName: "arrow.right")
                        .font(.gwaTopSystem(size: 12, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    DatePicker("", selection: $commonEnd, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Spacer()
                }
            }
            Text("선택한 요일은 모두 같은 시간으로 저장돼요.")
                .font(.gwaTopSystem(size: 11, weight: .medium))
                .foregroundStyle(GwaTopHomeTheme.textTertiary)

            Divider().padding(.vertical, 2)

            // ── 예외: 특정 요일만 다른 시간/강의실 ──
            HStack {
                fieldLabel("예외 — 다른 시간·강의실")
                Spacer()
                Button {
                    addException()
                } label: {
                    Label("예외 추가", systemImage: "plus.circle.fill")
                        .font(.gwaTopSystem(size: 13, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.primary)
                }
            }

            if exceptions.isEmpty {
                Text("특정 요일만 시간이 다르면 예외를 추가하세요.")
                    .font(.gwaTopSystem(size: 12, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textTertiary)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(exceptions.enumerated()), id: \.offset) { idx, _ in
                        GwaTopClassTimeRow(
                            time: $exceptions[idx],
                            onDelete: { exceptions.remove(at: idx) }
                        )
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GwaTopHomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 공통 시간으로 반복할 요일을 여러 개 토글. 예외로 지정된 요일은 예외가 우선하므로
    /// 여기서는 비활성(예외 칩 스타일)으로 표시한다.
    private var commonDayPicker: some View {
        HStack(spacing: 6) {
            ForEach(GwaTopDayLabels, id: \.code) { d in
                let isException = exceptions.contains { $0.day == d.code }
                let isOn = commonDays.contains(d.code)
                Button {
                    if commonDays.contains(d.code) {
                        commonDays.remove(d.code)
                    } else {
                        commonDays.insert(d.code)
                    }
                } label: {
                    Text(d.label)
                        .font(.gwaTopSystem(size: 13, weight: .bold))
                        .foregroundStyle(dayForeground(isOn: isOn, isException: isException))
                        .frame(width: 30, height: 30)
                        .background(dayBackground(isOn: isOn, isException: isException))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isException)
            }
        }
    }

    private func dayForeground(isOn: Bool, isException: Bool) -> Color {
        if isException { return GwaTopHomeTheme.primary }
        return isOn ? .white : GwaTopHomeTheme.textPrimary
    }

    private func dayBackground(isOn: Bool, isException: Bool) -> Color {
        if isException { return GwaTopHomeTheme.primary.opacity(0.16) }
        return isOn ? GwaTopHomeTheme.primary : GwaTopHomeTheme.surfaceMute
    }

    /// 예외 추가 — 아직 안 쓴 요일을 기본값으로, 시간은 공통 시간으로 채운다.
    private func addException() {
        let used = commonDays.union(exceptions.map(\.day))
        let day = dayOrder.first { !used.contains($0) } ?? "MON"
        exceptions.append(GwaTopClassTimeDTO(
            day: day,
            startTime: gwaTopHHMM(from: commonStart),
            endTime: gwaTopHHMM(from: commonEnd)
        ))
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            HStack(spacing: 6) {
                if isSubmitting { ProgressView().tint(.white) }
                Text(isSubmitting ? "저장 중…" : "저장")
                    .font(.gwaTopSystem(size: 16, weight: .heavy))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(canSave ? GwaTopHomeTheme.primary : GwaTopHomeTheme.controlDisabled)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(!canSave)
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            confirmDelete = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                Text("이 과목 삭제")
                    .font(.gwaTopSystem(size: 14, weight: .bold))
            }
            .foregroundStyle(GwaTopHomeTheme.danger)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(GwaTopHomeTheme.danger.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var canSave: Bool {
        !isSubmitting && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: 액션

    @MainActor
    private func save() async {
        guard canSave else { return }
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }
        do {
            let updated = try await GwaTopCourseService.shared.update(
                id: course.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                professor: professor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : professor,
                color: color,
                location: location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : location,
                schedule: buildSchedule()
            )
            onSaved?(updated)
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func deleteCourse() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await GwaTopCourseService.shared.delete(id: course.id)
            onDeleted?(course.id)
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: 공통 헬퍼

    private func fieldLabel(_ s: String) -> some View {
        Text(s)
            .font(.gwaTopSystem(size: 12, weight: .bold))
            .foregroundStyle(GwaTopHomeTheme.textSecondary)
    }
}

// MARK: - 2) 시간표 + 버튼 → 새 슬롯 추가 시트

struct GwaTopTimetableAddSheet: View {
    let existingCourses: [GwaTopCourseDTO]
    let activeSemesterId: String?
    /// 시작 시점 사전 선택 — 그리드 빈 칸을 탭해서 진입했을 때 day/시간 미리 채움.
    var defaultDay: String = "MON"
    var defaultStart: String = "09:00"
    var defaultEnd: String = "10:30"

    /// 저장 성공 시 호출 — 부모가 courses 갱신.
    var onSaved: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    enum Mode: String { case existing, new }
    @State private var mode: Mode = .existing
    @State private var selectedCourseId: String? = nil

    // 새 과목 모드용 입력값.
    @State private var newName: String = ""
    @State private var newProfessor: String = ""
    @State private var newLocation: String = ""
    @State private var newColor: String = GwaTopCoursePalette[0]

    // 시간 입력
    @State private var day: String
    @State private var startTime: Date
    @State private var endTime: Date

    @State private var isSubmitting = false
    @State private var error: String? = nil

    init(
        existingCourses: [GwaTopCourseDTO],
        activeSemesterId: String?,
        defaultDay: String = "MON",
        defaultStart: String = "09:00",
        defaultEnd: String = "10:30",
        onSaved: (() -> Void)? = nil
    ) {
        self.existingCourses = existingCourses
        self.activeSemesterId = activeSemesterId
        self.defaultDay = defaultDay
        self.defaultStart = defaultStart
        self.defaultEnd = defaultEnd
        self.onSaved = onSaved
        _day = State(initialValue: defaultDay)
        _startTime = State(initialValue: gwaTopDate(fromHHMM: defaultStart))
        _endTime = State(initialValue: gwaTopDate(fromHHMM: defaultEnd))
        _selectedCourseId = State(initialValue: existingCourses.first?.id)
        _mode = State(initialValue: existingCourses.isEmpty ? .new : .existing)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GwaTopHomeTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        modeSegment
                        if mode == .existing {
                            existingPicker
                        } else {
                            newCourseFields
                        }
                        timeBlock
                        if let err = error {
                            Text(err)
                                .font(.gwaTopSystem(size: 13, weight: .semibold))
                                .foregroundStyle(GwaTopHomeTheme.danger)
                        }
                        submitButton
                    }
                    .padding(20)
                }
            }
            .navigationTitle("시간표에 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") { dismiss() }
                }
            }
        }
    }

    // MARK: 모드 segment

    private var modeSegment: some View {
        HStack(spacing: 8) {
            modeChip("기존 과목에 추가", on: mode == .existing) {
                guard !existingCourses.isEmpty else { return }
                mode = .existing
            }
            .disabled(existingCourses.isEmpty)
            modeChip("새 과목 만들기", on: mode == .new) { mode = .new }
        }
    }

    private func modeChip(_ title: String, on active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.gwaTopSystem(size: 14, weight: .bold))
                .foregroundStyle(active ? .white : GwaTopHomeTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(active ? GwaTopHomeTheme.primary : GwaTopHomeTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: 기존 과목 선택

    private var existingPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("과목")
            if existingCourses.isEmpty {
                Text("아직 등록된 과목이 없어요. '새 과목 만들기' 로 추가하세요.")
                    .font(.gwaTopSystem(size: 13, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(existingCourses) { c in
                            coursePill(c)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GwaTopHomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func coursePill(_ c: GwaTopCourseDTO) -> some View {
        let selected = selectedCourseId == c.id
        return Button {
            selectedCourseId = c.id
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(c.color.map(Color.gwaTopHex) ?? GwaTopHomeTheme.primary)
                    .frame(width: 10, height: 10)
                Text(c.name.isEmpty ? "이름 없는 과목" : c.name)
                    .font(.gwaTopSystem(size: 14, weight: .bold))
                    .foregroundStyle(selected ? .white : GwaTopHomeTheme.textPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? GwaTopHomeTheme.primary : GwaTopHomeTheme.surfaceMute)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 새 과목 만들기 폼

    private var newCourseFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel("과목명")
            TextField("예: 자료구조와 알고리즘", text: $newName)
                .font(.gwaTopSystem(size: 15, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(GwaTopHomeTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10).strokeBorder(
                        GwaTopHomeTheme.primary.opacity(0.25), lineWidth: 1
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            fieldLabel("교수 (선택)")
            TextField("예: 김교수", text: $newProfessor)
                .font(.gwaTopSystem(size: 15))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(GwaTopHomeTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            fieldLabel("강의실 (선택)")
            TextField("예: 공학관 301호", text: $newLocation)
                .font(.gwaTopSystem(size: 15))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(GwaTopHomeTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            fieldLabel("색상")
            HStack(spacing: 10) {
                ForEach(GwaTopCoursePalette, id: \.self) { hex in
                    Button { newColor = hex } label: {
                        Circle()
                            .fill(Color.gwaTopHex(hex))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .stroke(GwaTopHomeTheme.textPrimary.opacity(newColor == hex ? 0.5 : 0), lineWidth: 2)
                                    .padding(-3)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(GwaTopHomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: 시간 입력

    private var timeBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel("요일")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(GwaTopDayLabels, id: \.code) { d in
                        Button {
                            day = d.code
                        } label: {
                            Text(d.label)
                                .font(.gwaTopSystem(size: 14, weight: .bold))
                                .foregroundStyle(day == d.code ? .white : GwaTopHomeTheme.textPrimary)
                                .frame(width: 42, height: 42)
                                .background(day == d.code ? GwaTopHomeTheme.primary : GwaTopHomeTheme.surfaceMute)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("시작")
                    DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .environment(\.locale, Locale(identifier: "ko_KR"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("종료")
                    DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .environment(\.locale, Locale(identifier: "ko_KR"))
                }
            }
        }
        .padding(16)
        .background(GwaTopHomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            HStack(spacing: 6) {
                if isSubmitting { ProgressView().tint(.white) }
                Text(isSubmitting ? "저장 중…" : "시간표에 추가")
                    .font(.gwaTopSystem(size: 16, weight: .heavy))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(canSubmit ? GwaTopHomeTheme.primary : GwaTopHomeTheme.controlDisabled)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!canSubmit)
    }

    private var canSubmit: Bool {
        guard !isSubmitting else { return false }
        guard endTime > startTime else { return false }
        switch mode {
        case .existing:
            return selectedCourseId != nil
        case .new:
            // 새 과목은 활성 학기 필요.
            return activeSemesterId != nil && !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @MainActor
    private func submit() async {
        error = nil
        isSubmitting = true
        defer { isSubmitting = false }
        let trimmedLocation = newLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        // 추가하는 슬롯(요일)에 강의실을 함께 저장 — 요일별 강의실 표시에 그대로 사용.
        let newSlot = GwaTopClassTimeDTO(
            day: day,
            startTime: gwaTopHHMM(from: startTime),
            endTime: gwaTopHHMM(from: endTime),
            location: trimmedLocation.isEmpty ? nil : trimmedLocation
        )
        do {
            switch mode {
            case .existing:
                guard let cid = selectedCourseId,
                      let target = existingCourses.first(where: { $0.id == cid }) else {
                    error = "과목을 선택해주세요."
                    return
                }
                let merged = (target.schedule ?? []) + [newSlot]
                _ = try await GwaTopCourseService.shared.update(
                    id: target.id, schedule: merged
                )
            case .new:
                guard let semId = activeSemesterId else {
                    error = "활성 학기가 없어 새 과목을 만들 수 없어요."
                    return
                }
                _ = try await GwaTopCourseService.shared.create(
                    semesterId: semId,
                    name: newName.trimmingCharacters(in: .whitespacesAndNewlines),
                    professor: newProfessor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newProfessor,
                    color: newColor,
                    location: trimmedLocation.isEmpty ? nil : trimmedLocation,
                    schedule: [newSlot]
                )
            }
            onSaved?()
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func fieldLabel(_ s: String) -> some View {
        Text(s)
            .font(.gwaTopSystem(size: 12, weight: .bold))
            .foregroundStyle(GwaTopHomeTheme.textSecondary)
    }
}

// MARK: - 시간 슬롯 한 줄 — 요일 + 시작/종료 + 삭제

struct GwaTopClassTimeRow: View {
    @Binding var time: GwaTopClassTimeDTO
    var onDelete: () -> Void

    @State private var start: Date
    @State private var end: Date

    init(time: Binding<GwaTopClassTimeDTO>, onDelete: @escaping () -> Void) {
        self._time = time
        self.onDelete = onDelete
        _start = State(initialValue: gwaTopDate(fromHHMM: time.wrappedValue.startTime))
        _end = State(initialValue: gwaTopDate(fromHHMM: time.wrappedValue.endTime))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(GwaTopDayLabels, id: \.code) { d in
                    Button {
                        // 요일만 바꾸고 시간·강의실은 그대로 유지.
                        time.day = d.code
                    } label: {
                        Text(d.label)
                            .font(.gwaTopSystem(size: 13, weight: .bold))
                            .foregroundStyle(time.day == d.code ? .white : GwaTopHomeTheme.textPrimary)
                            .frame(width: 30, height: 30)
                            .background(time.day == d.code ? GwaTopHomeTheme.primary : GwaTopHomeTheme.surfaceMute)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash.circle.fill")
                        .font(.gwaTopSystem(size: 22, weight: .regular))
                        .foregroundStyle(GwaTopHomeTheme.danger.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                DatePicker("", selection: $start, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .onChange(of: start) { _, newValue in
                        time.startTime = gwaTopHHMM(from: newValue)
                    }
                Image(systemName: "arrow.right")
                    .font(.gwaTopSystem(size: 12, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                DatePicker("", selection: $end, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .onChange(of: end) { _, newValue in
                        time.endTime = gwaTopHHMM(from: newValue)
                    }
            }
            // 요일별 강의실 — 슬롯마다 개별 입력 (예: 월 공학관 301, 수 IT관 105).
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.gwaTopSystem(size: 13, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                TextField("강의실 (예: 공학관 301호)", text: Binding(
                    get: { time.location ?? "" },
                    set: { time.location = $0.isEmpty ? nil : $0 }
                ))
                .font(.gwaTopSystem(size: 14, weight: .medium))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GwaTopHomeTheme.surfaceMute)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
