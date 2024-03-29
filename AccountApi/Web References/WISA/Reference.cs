﻿//------------------------------------------------------------------------------
// <auto-generated>
//     This code was generated by a tool.
//     Runtime Version:4.0.30319.42000
//
//     Changes to this file may cause incorrect behavior and will be lost if
//     the code is regenerated.
// </auto-generated>
//------------------------------------------------------------------------------

// 
// This source code was auto-generated by Microsoft.VSDesigner, Version 4.0.30319.42000.
// 
#pragma warning disable 1591

namespace AccountApi.WISA {
    using System.Diagnostics;
    using System;
    using System.Xml.Serialization;
    using System.ComponentModel;
    using System.Web.Services.Protocols;
    using System.Web.Services;
    
    
    /// <remarks/>
    [System.CodeDom.Compiler.GeneratedCodeAttribute("System.Web.Services", "4.8.4084.0")]
    [System.Diagnostics.DebuggerStepThroughAttribute()]
    [System.ComponentModel.DesignerCategoryAttribute("code")]
    [System.Web.Services.WebServiceBindingAttribute(Name="WisaAPIServiceBinding", Namespace="http://tempuri.org/")]
    [System.Xml.Serialization.SoapIncludeAttribute(typeof(TWISAAPIParamValue))]
    public partial class WisaAPIServiceService : System.Web.Services.Protocols.SoapHttpClientProtocol {
        
        private System.Threading.SendOrPostCallback GetExportDataOperationCompleted;
        
        private System.Threading.SendOrPostCallback GetCSVDataOperationCompleted;
        
        private System.Threading.SendOrPostCallback GetXMLDataOperationCompleted;
        
        private bool useDefaultCredentialsSetExplicitly;
        
        /// <remarks/>
        public WisaAPIServiceService() {
            if ((this.IsLocalFileSystemWebService(this.Url) == true)) {
                this.UseDefaultCredentials = true;
                this.useDefaultCredentialsSetExplicitly = false;
            }
            else {
                this.useDefaultCredentialsSetExplicitly = true;
            }
        }
        
        public new string Url {
            get {
                return base.Url;
            }
            set {
                if ((((this.IsLocalFileSystemWebService(base.Url) == true) 
                            && (this.useDefaultCredentialsSetExplicitly == false)) 
                            && (this.IsLocalFileSystemWebService(value) == false))) {
                    base.UseDefaultCredentials = false;
                }
                base.Url = value;
            }
        }
        
        public new bool UseDefaultCredentials {
            get {
                return base.UseDefaultCredentials;
            }
            set {
                base.UseDefaultCredentials = value;
                this.useDefaultCredentialsSetExplicitly = true;
            }
        }
        
        /// <remarks/>
        public event GetExportDataCompletedEventHandler GetExportDataCompleted;
        
        /// <remarks/>
        public event GetCSVDataCompletedEventHandler GetCSVDataCompleted;
        
        /// <remarks/>
        public event GetXMLDataCompletedEventHandler GetXMLDataCompleted;
        
        /// <remarks/>
        [System.Web.Services.Protocols.SoapRpcMethodAttribute("urn:WisaAPIService-WisaAPIService#GetExportData", RequestNamespace="urn:WisaAPIService-WisaAPIService", ResponseNamespace="urn:WisaAPIService-WisaAPIService")]
        [return: System.Xml.Serialization.SoapElementAttribute("Result", DataType="base64Binary")]
        public byte[] GetExportData(TWISAAPICredentials Credentials, string QueryCode, string Format, TWISAAPIParamValue[] Params, string Options) {
            object[] results = this.Invoke("GetExportData", new object[] {
                        Credentials,
                        QueryCode,
                        Format,
                        Params,
                        Options});
            return ((byte[])(results[0]));
        }
        
        /// <remarks/>
        public void GetExportDataAsync(TWISAAPICredentials Credentials, string QueryCode, string Format, TWISAAPIParamValue[] Params, string Options) {
            this.GetExportDataAsync(Credentials, QueryCode, Format, Params, Options, null);
        }
        
        /// <remarks/>
        public void GetExportDataAsync(TWISAAPICredentials Credentials, string QueryCode, string Format, TWISAAPIParamValue[] Params, string Options, object userState) {
            if ((this.GetExportDataOperationCompleted == null)) {
                this.GetExportDataOperationCompleted = new System.Threading.SendOrPostCallback(this.OnGetExportDataOperationCompleted);
            }
            this.InvokeAsync("GetExportData", new object[] {
                        Credentials,
                        QueryCode,
                        Format,
                        Params,
                        Options}, this.GetExportDataOperationCompleted, userState);
        }
        
        private void OnGetExportDataOperationCompleted(object arg) {
            if ((this.GetExportDataCompleted != null)) {
                System.Web.Services.Protocols.InvokeCompletedEventArgs invokeArgs = ((System.Web.Services.Protocols.InvokeCompletedEventArgs)(arg));
                this.GetExportDataCompleted(this, new GetExportDataCompletedEventArgs(invokeArgs.Results, invokeArgs.Error, invokeArgs.Cancelled, invokeArgs.UserState));
            }
        }
        
        /// <remarks/>
        [System.Web.Services.Protocols.SoapRpcMethodAttribute("urn:WisaAPIService-WisaAPIService#GetCSVData", RequestNamespace="urn:WisaAPIService-WisaAPIService", ResponseNamespace="urn:WisaAPIService-WisaAPIService")]
        [return: System.Xml.Serialization.SoapElementAttribute("Result", DataType="base64Binary")]
        public byte[] GetCSVData(TWISAAPICredentials Credentials, string QueryCode, TWISAAPIParamValue[] Params, bool Header, string Separator, string Options) {
            object[] results = this.Invoke("GetCSVData", new object[] {
                        Credentials,
                        QueryCode,
                        Params,
                        Header,
                        Separator,
                        Options});
            return ((byte[])(results[0]));
        }
        
        /// <remarks/>
        public void GetCSVDataAsync(TWISAAPICredentials Credentials, string QueryCode, TWISAAPIParamValue[] Params, bool Header, string Separator, string Options) {
            this.GetCSVDataAsync(Credentials, QueryCode, Params, Header, Separator, Options, null);
        }
        
        /// <remarks/>
        public void GetCSVDataAsync(TWISAAPICredentials Credentials, string QueryCode, TWISAAPIParamValue[] Params, bool Header, string Separator, string Options, object userState) {
            if ((this.GetCSVDataOperationCompleted == null)) {
                this.GetCSVDataOperationCompleted = new System.Threading.SendOrPostCallback(this.OnGetCSVDataOperationCompleted);
            }
            this.InvokeAsync("GetCSVData", new object[] {
                        Credentials,
                        QueryCode,
                        Params,
                        Header,
                        Separator,
                        Options}, this.GetCSVDataOperationCompleted, userState);
        }
        
        private void OnGetCSVDataOperationCompleted(object arg) {
            if ((this.GetCSVDataCompleted != null)) {
                System.Web.Services.Protocols.InvokeCompletedEventArgs invokeArgs = ((System.Web.Services.Protocols.InvokeCompletedEventArgs)(arg));
                this.GetCSVDataCompleted(this, new GetCSVDataCompletedEventArgs(invokeArgs.Results, invokeArgs.Error, invokeArgs.Cancelled, invokeArgs.UserState));
            }
        }
        
        /// <remarks/>
        [System.Web.Services.Protocols.SoapRpcMethodAttribute("urn:WisaAPIService-WisaAPIService#GetXMLData", RequestNamespace="urn:WisaAPIService-WisaAPIService", ResponseNamespace="urn:WisaAPIService-WisaAPIService")]
        [return: System.Xml.Serialization.SoapElementAttribute("Result", DataType="base64Binary")]
        public byte[] GetXMLData(TWISAAPICredentials Credentials, string QueryCode, TWISAAPIParamValue[] Params, int XMLFormat, string Options) {
            object[] results = this.Invoke("GetXMLData", new object[] {
                        Credentials,
                        QueryCode,
                        Params,
                        XMLFormat,
                        Options});
            return ((byte[])(results[0]));
        }
        
        /// <remarks/>
        public void GetXMLDataAsync(TWISAAPICredentials Credentials, string QueryCode, TWISAAPIParamValue[] Params, int XMLFormat, string Options) {
            this.GetXMLDataAsync(Credentials, QueryCode, Params, XMLFormat, Options, null);
        }
        
        /// <remarks/>
        public void GetXMLDataAsync(TWISAAPICredentials Credentials, string QueryCode, TWISAAPIParamValue[] Params, int XMLFormat, string Options, object userState) {
            if ((this.GetXMLDataOperationCompleted == null)) {
                this.GetXMLDataOperationCompleted = new System.Threading.SendOrPostCallback(this.OnGetXMLDataOperationCompleted);
            }
            this.InvokeAsync("GetXMLData", new object[] {
                        Credentials,
                        QueryCode,
                        Params,
                        XMLFormat,
                        Options}, this.GetXMLDataOperationCompleted, userState);
        }
        
        private void OnGetXMLDataOperationCompleted(object arg) {
            if ((this.GetXMLDataCompleted != null)) {
                System.Web.Services.Protocols.InvokeCompletedEventArgs invokeArgs = ((System.Web.Services.Protocols.InvokeCompletedEventArgs)(arg));
                this.GetXMLDataCompleted(this, new GetXMLDataCompletedEventArgs(invokeArgs.Results, invokeArgs.Error, invokeArgs.Cancelled, invokeArgs.UserState));
            }
        }
        
        /// <remarks/>
        public new void CancelAsync(object userState) {
            base.CancelAsync(userState);
        }
        
        private bool IsLocalFileSystemWebService(string url) {
            if (((url == null) 
                        || (url == string.Empty))) {
                return false;
            }
            System.Uri wsUri = new System.Uri(url);
            if (((wsUri.Port >= 1024) 
                        && (string.Compare(wsUri.Host, "localHost", System.StringComparison.OrdinalIgnoreCase) == 0))) {
                return true;
            }
            return false;
        }
    }
    
    /// <remarks/>
    [System.CodeDom.Compiler.GeneratedCodeAttribute("System.Xml", "4.8.4084.0")]
    [System.SerializableAttribute()]
    [System.Diagnostics.DebuggerStepThroughAttribute()]
    [System.ComponentModel.DesignerCategoryAttribute("code")]
    [System.Xml.Serialization.SoapTypeAttribute(Namespace="urn:WisaAPIService")]
    public partial class TWISAAPICredentials {
        
        private string usernameField;
        
        private string passwordField;
        
        private string databaseField;
        
        /// <remarks/>
        public string Username {
            get {
                return this.usernameField;
            }
            set {
                this.usernameField = value;
            }
        }
        
        /// <remarks/>
        public string Password {
            get {
                return this.passwordField;
            }
            set {
                this.passwordField = value;
            }
        }
        
        /// <remarks/>
        public string Database {
            get {
                return this.databaseField;
            }
            set {
                this.databaseField = value;
            }
        }
    }
    
    /// <remarks/>
    [System.CodeDom.Compiler.GeneratedCodeAttribute("System.Xml", "4.8.4084.0")]
    [System.SerializableAttribute()]
    [System.Diagnostics.DebuggerStepThroughAttribute()]
    [System.ComponentModel.DesignerCategoryAttribute("code")]
    [System.Xml.Serialization.SoapTypeAttribute(Namespace="urn:WisaAPIService")]
    public partial class TWISAAPIParamValue {
        
        private string nameField;
        
        private string valueField;
        
        /// <remarks/>
        public string Name {
            get {
                return this.nameField;
            }
            set {
                this.nameField = value;
            }
        }
        
        /// <remarks/>
        public string Value {
            get {
                return this.valueField;
            }
            set {
                this.valueField = value;
            }
        }
    }
    
    /// <remarks/>
    [System.CodeDom.Compiler.GeneratedCodeAttribute("System.Web.Services", "4.8.4084.0")]
    public delegate void GetExportDataCompletedEventHandler(object sender, GetExportDataCompletedEventArgs e);
    
    /// <remarks/>
    [System.CodeDom.Compiler.GeneratedCodeAttribute("System.Web.Services", "4.8.4084.0")]
    [System.Diagnostics.DebuggerStepThroughAttribute()]
    [System.ComponentModel.DesignerCategoryAttribute("code")]
    public partial class GetExportDataCompletedEventArgs : System.ComponentModel.AsyncCompletedEventArgs {
        
        private object[] results;
        
        internal GetExportDataCompletedEventArgs(object[] results, System.Exception exception, bool cancelled, object userState) : 
                base(exception, cancelled, userState) {
            this.results = results;
        }
        
        /// <remarks/>
        public byte[] Result {
            get {
                this.RaiseExceptionIfNecessary();
                return ((byte[])(this.results[0]));
            }
        }
    }
    
    /// <remarks/>
    [System.CodeDom.Compiler.GeneratedCodeAttribute("System.Web.Services", "4.8.4084.0")]
    public delegate void GetCSVDataCompletedEventHandler(object sender, GetCSVDataCompletedEventArgs e);
    
    /// <remarks/>
    [System.CodeDom.Compiler.GeneratedCodeAttribute("System.Web.Services", "4.8.4084.0")]
    [System.Diagnostics.DebuggerStepThroughAttribute()]
    [System.ComponentModel.DesignerCategoryAttribute("code")]
    public partial class GetCSVDataCompletedEventArgs : System.ComponentModel.AsyncCompletedEventArgs {
        
        private object[] results;
        
        internal GetCSVDataCompletedEventArgs(object[] results, System.Exception exception, bool cancelled, object userState) : 
                base(exception, cancelled, userState) {
            this.results = results;
        }
        
        /// <remarks/>
        public byte[] Result {
            get {
                this.RaiseExceptionIfNecessary();
                return ((byte[])(this.results[0]));
            }
        }
    }
    
    /// <remarks/>
    [System.CodeDom.Compiler.GeneratedCodeAttribute("System.Web.Services", "4.8.4084.0")]
    public delegate void GetXMLDataCompletedEventHandler(object sender, GetXMLDataCompletedEventArgs e);
    
    /// <remarks/>
    [System.CodeDom.Compiler.GeneratedCodeAttribute("System.Web.Services", "4.8.4084.0")]
    [System.Diagnostics.DebuggerStepThroughAttribute()]
    [System.ComponentModel.DesignerCategoryAttribute("code")]
    public partial class GetXMLDataCompletedEventArgs : System.ComponentModel.AsyncCompletedEventArgs {
        
        private object[] results;
        
        internal GetXMLDataCompletedEventArgs(object[] results, System.Exception exception, bool cancelled, object userState) : 
                base(exception, cancelled, userState) {
            this.results = results;
        }
        
        /// <remarks/>
        public byte[] Result {
            get {
                this.RaiseExceptionIfNecessary();
                return ((byte[])(this.results[0]));
            }
        }
    }
}

#pragma warning restore 1591