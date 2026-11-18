import SwiftUI

@MainActor
struct JourneyReturnEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let store: JourneySearchStore

    var body: some View {
        Form {
            Section(JourneySearchCopy.returnDirection) {
                Picker(JourneySearchCopy.Form.searchBy, selection: arriveBy) {
                    Text(JourneySearchCopy.Form.departAt).tag(false)
                    Text(JourneySearchCopy.Form.arriveBy).tag(true)
                }
                .pickerStyle(.segmented)

                DatePicker(
                    JourneySearchCopy.Form.returnDateAndTime,
                    selection: returnTime,
                    in: store.form.outboundTime...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .environment(\.timeZone, returnTimeZone)
            }
            .trainTrackerRowSurface()

            Section {
                Button {
                    store.searchReturn()
                    dismiss()
                } label: {
                    Text(JourneySearchCopy.ReturnEditor.searchReturns)
                        .trainTrackerFullWidthAction()
                }
                .trainTrackerPrimaryAction()
            } footer: {
                Text(JourneySearchCopy.ReturnEditor.selectionPreserved)
            }
            .trainTrackerRowSurface()
        }
        .formStyle(.grouped)
        .trainTrackerListCanvas()
        .navigationTitle(JourneySearchCopy.ReturnEditor.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var arriveBy: Binding<Bool> {
        Binding(
            get: { store.form.returnArriveBy },
            set: { store.setReturnArriveBy($0) }
        )
    }

    private var returnTime: Binding<Date> {
        Binding(
            get: { store.form.returnTime },
            set: { store.setReturnTime($0) }
        )
    }

    private var returnTimeZone: TimeZone {
        store.form.returnTimeZoneIdentifier.flatMap(TimeZone.init(identifier:))
            ?? .autoupdatingCurrent
    }
}
