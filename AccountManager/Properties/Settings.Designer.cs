﻿//------------------------------------------------------------------------------
// <auto-generated>
//     This code was generated by a tool.
//     Runtime Version:4.0.30319.42000
//
//     Changes to this file may cause incorrect behavior and will be lost if
//     the code is regenerated.
// </auto-generated>
//------------------------------------------------------------------------------

namespace AccountManager.Properties {
    
    
    [global::System.Runtime.CompilerServices.CompilerGeneratedAttribute()]
    [global::System.CodeDom.Compiler.GeneratedCodeAttribute("Microsoft.VisualStudio.Editors.SettingsDesigner.SettingsSingleFileGenerator", "15.9.0.0")]
    internal sealed partial class Settings : global::System.Configuration.ApplicationSettingsBase {
        
        private static Settings defaultInstance = ((Settings)(global::System.Configuration.ApplicationSettingsBase.Synchronized(new Settings())));
        
        public static Settings Default {
            get {
                return defaultInstance;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.Configuration.DefaultSettingValueAttribute("test")]
        public string WisaServer {
            get {
                return ((string)(this["WisaServer"]));
            }
            set {
                this["WisaServer"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.Configuration.DefaultSettingValueAttribute("")]
        public string WisaPort {
            get {
                return ((string)(this["WisaPort"]));
            }
            set {
                this["WisaPort"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.Configuration.DefaultSettingValueAttribute("")]
        public string WisaDatabase {
            get {
                return ((string)(this["WisaDatabase"]));
            }
            set {
                this["WisaDatabase"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.Configuration.DefaultSettingValueAttribute("")]
        public string WisaUser {
            get {
                return ((string)(this["WisaUser"]));
            }
            set {
                this["WisaUser"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.Configuration.DefaultSettingValueAttribute("")]
        public string WisaPassword {
            get {
                return ((string)(this["WisaPassword"]));
            }
            set {
                this["WisaPassword"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.Configuration.DefaultSettingValueAttribute("Unknown")]
        public global::AbstractAccountApi.ConfigState WisaConnectionTested {
            get {
                return ((global::AbstractAccountApi.ConfigState)(this["WisaConnectionTested"]));
            }
            set {
                this["WisaConnectionTested"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        public global::System.DateTime WisaWorkDate {
            get {
                return ((global::System.DateTime)(this["WisaWorkDate"]));
            }
            set {
                this["WisaWorkDate"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.Configuration.DefaultSettingValueAttribute("True")]
        public bool WisaWorkDateNow {
            get {
                return ((bool)(this["WisaWorkDateNow"]));
            }
            set {
                this["WisaWorkDateNow"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.Configuration.DefaultSettingValueAttribute("")]
        public string SmartschoolURI {
            get {
                return ((string)(this["SmartschoolURI"]));
            }
            set {
                this["SmartschoolURI"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.Configuration.DefaultSettingValueAttribute("")]
        public string SmartschoolPassphrase {
            get {
                return ((string)(this["SmartschoolPassphrase"]));
            }
            set {
                this["SmartschoolPassphrase"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.Configuration.DefaultSettingValueAttribute("")]
        public string SmartschoolTestUser {
            get {
                return ((string)(this["SmartschoolTestUser"]));
            }
            set {
                this["SmartschoolTestUser"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.Configuration.DefaultSettingValueAttribute("Unknown")]
        public global::AbstractAccountApi.ConfigState SmartschoolConnectionTested {
            get {
                return ((global::AbstractAccountApi.ConfigState)(this["SmartschoolConnectionTested"]));
            }
            set {
                this["SmartschoolConnectionTested"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.Configuration.DefaultSettingValueAttribute("")]
        public string SmartschoolStudentGroup {
            get {
                return ((string)(this["SmartschoolStudentGroup"]));
            }
            set {
                this["SmartschoolStudentGroup"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.Configuration.DefaultSettingValueAttribute("")]
        public string SmartschoolStaffGroup {
            get {
                return ((string)(this["SmartschoolStaffGroup"]));
            }
            set {
                this["SmartschoolStaffGroup"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.Configuration.DefaultSettingValueAttribute("False")]
        public bool SmartschoolUseGrades {
            get {
                return ((bool)(this["SmartschoolUseGrades"]));
            }
            set {
                this["SmartschoolUseGrades"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.Configuration.DefaultSettingValueAttribute("False")]
        public bool SmartschoolUseYears {
            get {
                return ((bool)(this["SmartschoolUseYears"]));
            }
            set {
                this["SmartschoolUseYears"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        public global::System.Collections.Specialized.StringCollection SmartschoolGrades {
            get {
                return ((global::System.Collections.Specialized.StringCollection)(this["SmartschoolGrades"]));
            }
            set {
                this["SmartschoolGrades"] = value;
            }
        }
        
        [global::System.Configuration.UserScopedSettingAttribute()]
        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        public global::System.Collections.Specialized.StringCollection SmartschoolYears {
            get {
                return ((global::System.Collections.Specialized.StringCollection)(this["SmartschoolYears"]));
            }
            set {
                this["SmartschoolYears"] = value;
            }
        }
    }
}
