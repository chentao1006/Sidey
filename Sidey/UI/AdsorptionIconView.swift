import SwiftUI

struct AdsorptionIconView: View {
    var onClick: () -> Void
    var onClickWithAssistant: (String) -> Void // Callback for specific assistant
    
    @ObservedObject private var dockingState = DockingState.shared
    @ObservedObject private var detector = ContextDetector.shared
    @ObservedObject private var promptStore = PromptStore.shared
    
    @State private var isHovered = false
    
    // Load official app icon
    private var appIcon: NSImage? {
        // AppIcon is the standard name in Info.plist/Assets
        return NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
    }
    
    var body: some View {
        let isRightSide = dockingState.isRightSide
        VStack(alignment: isRightSide ? .leading : .trailing, spacing: 1) { // Minimal spacing
            ZStack {
                // Background fallback
                TabShape(cornerRadius: 12, isRightSide: isRightSide)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.9))
                
                // Use AppIcon to FILL the entire tab area
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .renderingMode(.original)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(TabShape(cornerRadius: 12, isRightSide: isRightSide))
                }
                
                // 1px Gray Border
                TabShape(cornerRadius: 12, isRightSide: isRightSide)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                
                // Highlight Overlay
                TabShape(cornerRadius: 12, isRightSide: isRightSide)
                    .fill(Color.white.opacity(isHovered ? 0.15 : 0))
            }
            .frame(width: 40, height: 40)
            .onTapGesture {
                onClick()
            }
            
            // Assistant List shown on hover
            if isHovered {
                let currentApp = detector.currentBundleID
                let prompts = promptStore.getPrompts(for: currentApp)
                
                if !prompts.isEmpty {
                    VStack(alignment: isRightSide ? .leading : .trailing, spacing: 1) {
                        ForEach(prompts.prefix(10), id: \.id) { prompt in
                            Button(action: {
                                onClickWithAssistant(prompt.id)
                            }) {
                                Text(prompt.name)
                            }
                            .buttonStyle(AssistantButtonStyle(isRightSide: isRightSide))
                        }
                    }
                    .padding(isRightSide ? .leading : .trailing, 0)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
            }
        }
        .padding(.top, 20)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                isHovered = hovering
            }
            // Sync with manager to adjust window frame size
            if DockingManager.shared.isIconHovered != hovering {
                DockingManager.shared.isIconHovered = hovering
            }
        }
        .scaleEffect(isHovered ? 1.05 : 1.0)
        // Adjust offset so it's flush in hover state
        .offset(x: isHovered ? 0 : (isRightSide ? -15 : 15)) 
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isRightSide ? .topLeading : .topTrailing)
    }
}

struct AssistantButtonStyle: ButtonStyle {
    var isRightSide: Bool
    @State private var isHovering = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 80)
            .background(
                AssistantListShape(isRightSide: isRightSide)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(isHovering ? 1.0 : 0.9))
            )
            .overlay(
                AssistantListShape(isRightSide: isRightSide)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .overlay(
                AssistantListShape(isRightSide: isRightSide)
                    .fill(Color.white.opacity(isHovering ? 0.1 : 0))
            )
            .foregroundColor(.primary)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

struct TabShape: Shape {
    var cornerRadius: CGFloat
    var isRightSide: Bool
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        if isRightSide {
            // App is on the LEFT. Straight edge on the LEFT.
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY + cornerRadius),
                        radius: cornerRadius, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
            path.addArc(center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
                        radius: cornerRadius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        } else {
            // App is on the RIGHT. Straight edge on the RIGHT.
            path.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius),
                        radius: cornerRadius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
            path.addArc(center: CGPoint(x: rect.minX + cornerRadius, y: rect.minY + cornerRadius),
                        radius: cornerRadius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
        
        return path
    }
}

struct AssistantListShape: Shape {
    var isRightSide: Bool
    var cornerRadius: CGFloat = 8
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        if isRightSide {
            // App is on the LEFT. Straight edge on the LEFT.
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY + cornerRadius),
                        radius: cornerRadius, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
            path.addArc(center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
                        radius: cornerRadius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        } else {
            // App is on the RIGHT. Straight edge on the RIGHT.
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.minX + cornerRadius, y: rect.minY + cornerRadius),
                        radius: cornerRadius, startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius))
            path.addArc(center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius),
                        radius: cornerRadius, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
        
        return path
    }
}
