//
//  GwaTopWidgetBundle.swift
//  GwaTopWidget (위젯 타겟 전용)
//
//  위젯 익스텐션의 진입점(@main). 이 파일이 없으면 principal class 가 없어
//  익스텐션이 launch 단계(_EXConnectionHandlerExtension willFinishLaunching)에서 죽는다.
//

import WidgetKit
import SwiftUI

@main
struct GwaTopWidgetBundle: WidgetBundle {
    var body: some Widget {
        GwaTopScheduleWidget()
        GwaTopCalendarWidget()
    }
}
