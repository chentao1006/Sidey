import sys
import re

def fix_pbxproj(path):
    with open(path, 'r') as f:
        content = f.read()

    # Generic file addition helper
    def add_build_files(content):
        if 'DockingManager.swift in Sources' in content: return content
        lines = [
            '\t\tC6C655F12F6C44B4003A4BBD /* DockingManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = C6C655FB2F6C44B4003A4BBD /* DockingManager.swift */; };',
            '\t\tC6C655F22F6C44B4003A4BBD /* AdsorptionIconView.swift in Sources */ = {isa = PBXBuildFile; fileRef = C6C655FC2F6C44B4003A4BBD /* AdsorptionIconView.swift */; };',
            '\t\tC6C655F32F6C44B4003A4BBD /* DockingManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = C6C655FB2F6C44B4003A4BBD /* DockingManager.swift */; };',
            '\t\tC6C655F42F6C44B4003A4BBD /* AdsorptionIconView.swift in Sources */ = {isa = PBXBuildFile; fileRef = C6C655FC2F6C44B4003A4BBD /* AdsorptionIconView.swift */; };',
            '\t\tC6C655F62F6C44B4003A4BBD /* DockingState.swift in Sources */ = {isa = PBXBuildFile; fileRef = C6C655F52F6C44B4003A4BBD /* DockingState.swift */; };',
            '\t\tC6C655F72F6C44B4003A4BBD /* DockingState.swift in Sources */ = {isa = PBXBuildFile; fileRef = C6C655F52F6C44B4003A4BBD /* DockingState.swift */; };',
        ]
        return content.replace('/* End PBXBuildFile section */', '\n'.join(lines) + '\n/* End PBXBuildFile section */')

    def add_file_refs(content):
        if 'DockingManager.swift */ =' in content: return content
        lines = [
            '\t\tC6C655FB2F6C44B4003A4BBD /* DockingManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DockingManager.swift; sourceTree = "<group>"; };',
            '\t\tC6C655FC2F6C44B4003A4BBD /* AdsorptionIconView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AdsorptionIconView.swift; sourceTree = "<group>"; };',
            '\t\tC6C655F52F6C44B4003A4BBD /* DockingState.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DockingState.swift; sourceTree = "<group>"; };',
        ]
        return content.replace('/* End PBXFileReference section */', '\n'.join(lines) + '\n/* End PBXFileReference section */')

    content = add_build_files(content)
    content = add_file_refs(content)

    # Use regex for groups and phases to handle tabs/newlines
    # Core Group
    content = re.sub(r'(C6C655462F6C44B4003A4BBD /\* Core \*/ = \{[^{]*children = \()', 
                    r'\1\n\t\t\t\tC6C655FB2F6C44B4003A4BBD /* DockingManager.swift */,\n\t\t\t\tC6C655F52F6C44B4003A4BBD /* DockingState.swift */,', content)
    
    # UI Group
    content = re.sub(r'(C6C655522F6C44B4003A4BBD /\* UI \*/ = \{[^{]*children = \()', 
                    r'\1\n\t\t\t\tC6C655FC2F6C44B4003A4BBD /* AdsorptionIconView.swift */,', content)

    # Phase 1
    content = re.sub(r'(C655F17F2F74EA820044CC01 /\* Sources \*/ = \{[^{]*files = \()', 
                    r'\1\n\t\t\t\tC6C655F12F6C44B4003A4BBD /* DockingManager.swift in Sources */,\n\t\t\t\tC6C655F22F6C44B4003A4BBD /* AdsorptionIconView.swift in Sources */,\n\t\t\t\tC6C655F62F6C44B4003A4BBD /* DockingState.swift in Sources */,', content)

    # Phase 2
    content = re.sub(r'(E5A0070129C12345001A2B3C /\* Sources \*/ = \{[^{]*files = \()', 
                    r'\1\n\t\t\t\tC6C655F32F6C44B4003A4BBD /* DockingManager.swift in Sources */,\n\t\t\t\tC6C655F42F6C44B4003A4BBD /* AdsorptionIconView.swift in Sources */,\n\t\t\t\tC6C655F72F6C44B4003A4BBD /* DockingState.swift in Sources */,', content)

    with open(path, 'w') as f:
        f.write(content)

if __name__ == '__main__':
    fix_pbxproj('Sidey.xcodeproj/project.pbxproj')
