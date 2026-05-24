import SwiftUI

struct ExportProgress: View {
    @ObservedObject var exportVM: ExportVM
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 60))
                    .foregroundColor(.accentColor)
                
                Text("Exporting Video")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                if let profile = exportVM.project {
                    Text(profile.title)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            VStack(spacing: 12) {
                ProgressView(value: exportVM.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 300)
                
                HStack {
                    Text("\(Int(exportVM.progress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if !exportVM.estimatedFileSize.isEmpty {
                        Text("Est. size: \(exportVM.estimatedFileSize)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if exportVM.isExporting {
                Button("Cancel") {
                    exportVM.cancelExport()
                    dismiss()
                }
                .buttonStyle(.bordered)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                    
                    Text("Export Complete!")
                        .font(.headline)
                    
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(32)
        .frame(width: 400, height: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(16)
        .shadow(radius: 20)
    }
}
