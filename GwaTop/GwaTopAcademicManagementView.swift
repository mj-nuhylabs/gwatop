//
//  GwaTopAcademicManagementView.swift
//  GwaTop
//
//  설정 → "학기 / 과목 관리" 진입점.
//  학기 리스트(활성 학기 표시) → 학기 탭 → 해당 학기의 과목 리스트 → 과목 추가/편집/삭제.
//  업로드 시트 내부의 "+ 새 과목 추가" 인라인 경로와 별개로,
//  사용자가 명시적으로 학사 데이터를 관리할 수 있는 표준 경로다.
//

import SwiftUI

struct GwaTopAcademicManagementView: View {
    @State private var semesters: [GwaTopSemesterDTO] = []
    @State private var courses: [GwaTopCourseDTO] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        List {
            if isLoading && semesters.isEmpty {
                HStack { ProgressView(); Text("불러오는 중…") }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                }
            }

            Section("학기") {
                if semesters.isEmpty && !isLoading {
                    Text("등록된 학기가 없습니다.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                ForEach(semesters) { semester in
                    NavigationLink {
                        GwaTopCourseListView(
                            semester: semester,
                            courses: courses.filter { $0.semesterId == semester.id },
                            onChanged: { Task { await reload() } }
                        )
                    } label: {
                        semesterRow(semester)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await deleteSemester(semester) }
                        } label: { Label("삭제", systemImage: "trash") }
                    }
                    .swipeActions(edge: .leading) {
                        if !semester.isActive {
                            Button {
                                Task { await setActive(semester) }
                            } label: { Label("활성", systemImage: "star.fill") }
                            .tint(.orange)
                        }
                    }
                }

                NavigationLink {
                    GwaTopNewSemesterFormView(onCreated: { _ in
                        Task { await reload() }
                    })
                } label: {
                    Label("새 학기 추가", systemImage: "plus.circle.fill")
                        .foregroundStyle(GwaTopHomeTheme.primary)
                        .fontWeight(.heavy)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("학기 / 과목 관리")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func semesterRow(_ s: GwaTopSemesterDTO) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(s.name)
                        .font(.system(size: 16, weight: .heavy))
                    if s.isActive {
                        Text("활성")
                            .font(.system(size: 10, weight: .heavy))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
                Text(formatDateRange(s.startDate, s.endDate))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            let count = courses.filter { $0.semesterId == s.id }.count
            Text("\(count)과목")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func reload() async {
        isLoading = true
        errorMessage = nil
        do {
            async let semTask = GwaTopSemesterService.shared.fetchAll()
            async let crsTask = GwaTopCourseService.shared.fetchAll()
            let (sList, cList) = try await (semTask, crsTask)
            self.semesters = sList
            self.courses = cList
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func deleteSemester(_ s: GwaTopSemesterDTO) async {
        do {
            try await GwaTopSemesterService.shared.delete(id: s.id)
            await reload()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func setActive(_ s: GwaTopSemesterDTO) async {
        do {
            _ = try await GwaTopSemesterService.shared.setActive(id: s.id)
            await reload()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func formatDateRange(_ a: Date, _ b: Date) -> String {
        let fmt = GwaTopDateFormatters.koShortDate
        return "\(fmt.string(from: a)) – \(fmt.string(from: b))"
    }
}


// MARK: - 학기 안의 과목 리스트

struct GwaTopCourseListView: View {
    let semester: GwaTopSemesterDTO
    @State var courses: [GwaTopCourseDTO]
    var onChanged: () -> Void = {}

    @State private var errorMessage: String? = nil

    var body: some View {
        List {
            if courses.isEmpty {
                Text("이 학기에 등록된 과목이 없습니다.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            ForEach(courses) { course in
                NavigationLink {
                    GwaTopCourseFormView(
                        mode: .edit(course),
                        defaultSemesterId: semester.id,
                        onSaved: { updated in
                            if let idx = courses.firstIndex(where: { $0.id == updated.id }) {
                                courses[idx] = updated
                            }
                            onChanged()
                        }
                    )
                } label: {
                    courseRow(course)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await deleteCourse(course) }
                    } label: { Label("삭제", systemImage: "trash") }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
            }

            NavigationLink {
                GwaTopCourseFormView(
                    mode: .create,
                    defaultSemesterId: semester.id,
                    onSaved: { newCourse in
                        if !courses.contains(where: { $0.id == newCourse.id }) {
                            courses.append(newCourse)
                            courses.sort { $0.name < $1.name }
                        }
                        onChanged()
                    }
                )
            } label: {
                Label("새 과목 추가", systemImage: "plus.circle.fill")
                    .foregroundStyle(GwaTopHomeTheme.primary)
                    .fontWeight(.heavy)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(semester.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func courseRow(_ c: GwaTopCourseDTO) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.gwaTopHex(c.color ?? "#4F8EF7"))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.system(size: 16, weight: .heavy))
                if let professor = c.professor, !professor.isEmpty {
                    Text(professor)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func deleteCourse(_ c: GwaTopCourseDTO) async {
        do {
            try await GwaTopCourseService.shared.delete(id: c.id)
            courses.removeAll { $0.id == c.id }
            onChanged()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
