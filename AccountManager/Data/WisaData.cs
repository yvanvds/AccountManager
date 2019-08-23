using AbstractAccountApi;
using AccountApi;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager
{
    public sealed partial class Data
    {
        private DateTime lastWisaAccountSync;
        public DateTime LastWisaAccountSync => lastWisaAccountSync;

        private DateTime lastWisaClassgroupSync;
        public DateTime LastWisaClassgroupSync => lastWisaClassgroupSync;

        public ObservableCollection<IRule> WisaImportRules { get; set; } = new ObservableCollection<IRule>(); 

        const string wisaSchoolsFile = "wisaSchools.json";
        const string wisaClassFile = "wisaClasses.json";
        const string wisaStudentsFile = "wisaStudents.json";

        private void LoadWisaConfig(JObject obj)
        {
            wisaServer = obj.ContainsKey("server") ? obj["server"].ToString() : "";
            wisaPort = obj.ContainsKey("port") ? obj["port"].ToString() : "";
            wisaDatabase = obj.ContainsKey("database") ? obj["database"].ToString() : "";
            wisaUser = obj.ContainsKey("user") ? obj["user"].ToString() : "";
            wisaPassword = obj.ContainsKey("password") ? obj["password"].ToString() : "";
            wisaConnectionTested = obj.ContainsKey("connectionTested") ? obj["connectionTested"].ToObject<ConfigState>() : ConfigState.Unknown;
            wisaWorkDateNow = obj.ContainsKey("workDateNow") ? obj["workDateNow"].ToObject<bool>() : true;

            // if WisaWorkDateNow is true, the current date is used as 'werkdatum'
            // if not, the saved date will be used
            if (WisaWorkDateNow)
            {
                wisaWorkDate = DateTime.Now;
            }
            else
            {
                wisaWorkDate = obj.ContainsKey("workDate") ? obj["workDate"].ToObject<DateTime>() : DateTime.Now;
            }

            if (obj.ContainsKey("importRules"))
            {
                var arr = obj["importRules"] as JArray;
                foreach (var item in arr)
                {
                    var data = item as JObject;
                    Rule rule = (Rule)data["Rule"].ToObject(typeof(Rule));
                    switch (rule)
                    {
                        case Rule.WI_ReplaceInstitution: WisaImportRules.Add(new AccountApi.Rules.ReplaceInstitute(data)); break;
                        case Rule.WI_DontImportClass: WisaImportRules.Add(new AccountApi.Rules.DontImportClass(data)); break;
                        case Rule.WI_MarkAsVirtual: WisaImportRules.Add(new AccountApi.Rules.MarkAsVirtual(data)); break;
                    }
                }
            }
        }

        private JObject SaveWisaConfig()
        {
            JObject result = new JObject
            {
                ["server"] = wisaServer,
                ["port"] = wisaPort,
                ["database"] = wisaDatabase,
                ["user"] = wisaUser,
                ["password"] = wisaPassword,
                ["connectionTested"] = wisaConnectionTested.ToString(),
                ["workDateNow"] = wisaWorkDateNow,
                ["workDate"] = wisaWorkDate
            };

            if (WisaImportRules.Count > 0)
            {
                var arr = new JArray();
                foreach(var rule in WisaImportRules)
                {
                    arr.Add(rule.ToJson());
                }
                result["importRules"] = arr;
            }

            return result;
        }

        private void LoadWisaFileContent()
        {
            SetWisaCredentials();

            var wisaSchoolsLocation = Path.Combine(appFolder, wisaSchoolsFile);
            if (File.Exists(wisaSchoolsLocation))
            {
                string content = File.ReadAllText(wisaSchoolsLocation);
                var newObj = Newtonsoft.Json.Linq.JObject.Parse(content);
                AccountApi.Wisa.SchoolManager.FromJson(newObj);
            }

            var wisaClassLocation = Path.Combine(appFolder, wisaClassFile);
            if (File.Exists(wisaClassLocation))
            {
                string content = File.ReadAllText(wisaClassLocation);
                var newObj = Newtonsoft.Json.Linq.JObject.Parse(content);
                AccountApi.Wisa.ClassGroupManager.FromJson(newObj);
                lastWisaClassgroupSync = newObj.ContainsKey("lastSync") ? Convert.ToDateTime(newObj["lastSync"]) : DateTime.MinValue;
            }

            var wisaStudentLocation = Path.Combine(appFolder, wisaStudentsFile);
            if (File.Exists(wisaStudentLocation))
            {
                string content = File.ReadAllText(wisaStudentLocation);
                var newObj = Newtonsoft.Json.Linq.JObject.Parse(content);
                AccountApi.Wisa.Students.FromJson(newObj);
                lastWisaAccountSync = newObj.ContainsKey("lastSync") ? Convert.ToDateTime(newObj["lastSync"]) : DateTime.MinValue;
            }
        }

        private string wisaServer;

        public string WisaServer
        {
            get { return wisaServer; }
            set
            {
                wisaServer = value.Trim();
                WisaConnectionTested = ConfigState.Unknown;
            }
        }

        private string wisaPort;

        public string WisaPort
        {
            get { return wisaPort; }
            set
            {
                wisaPort = value.Trim();
                WisaConnectionTested = ConfigState.Unknown;
            }
        }

        private string wisaDatabase;

        public string WisaDatabase
        {
            get { return wisaDatabase; }
            set
            {
                wisaDatabase = value.Trim();
                WisaConnectionTested = ConfigState.Unknown;
            }
        }

        private string wisaUser;

        public string WisaUser
        {
            get { return wisaUser; }
            set
            {
                wisaUser = value.Trim();
                WisaConnectionTested = ConfigState.Unknown;
            }
        }

        private string wisaPassword;

        public string WisaPassword
        {
            get { return wisaPassword; }
            set
            {
                wisaPassword = value.Trim();
                WisaConnectionTested = ConfigState.Unknown;
            }
        }

        private ConfigState wisaConnectionTested;

        public ConfigState WisaConnectionTested
        {
            get { return wisaConnectionTested; }
            set
            {
                wisaConnectionTested = value;
                ConfigChanged = true;
            }
        }

        // if this is true, we will use the current date.
        // if not, the saved workdate will be used.
        private bool wisaWorkDateNow = true;
        public bool WisaWorkDateNow
        {
            get => wisaWorkDateNow;
            set
            {
                wisaWorkDateNow = value;
                ConfigChanged = true;
            }
        }

        private DateTime wisaWorkDate = DateTime.Now;
        public DateTime WisaWorkDate
        {
            get => wisaWorkDate;
            set
            {
                wisaWorkDate = value;
                ConfigChanged = true;
            }
        }

        public void SetWisaCredentials()
        {
            int port = 0;
            try
            {
                port = Convert.ToInt32(WisaPort);
            }
            catch (Exception)
            {
                MainWindow.Instance.Log.AddError(Origin.Wisa, "Port should be a number");
                return;
            }


            AccountApi.Wisa.Connector.Init(
                WisaServer, port, WisaUser, WisaPassword, WisaDatabase, MainWindow.Instance.Log
            );
        }

        public async Task ReloadWisaSchools()
        {
            // remember which schools are selected
            List<int> selected = new List<int>();
            foreach (var school in AccountApi.Wisa.SchoolManager.All)
            {
                if (school.IsActive) selected.Add(school.ID);
            }

            // reload list of schools
            bool result = await AccountApi.Wisa.SchoolManager.Load();

            // only save changes if the request succeeded
            if (result)
            {
                // set to selected if the previous had them selected
                foreach (var school in AccountApi.Wisa.SchoolManager.All)
                {
                    if (selected.Contains(school.ID))
                    {
                        school.IsActive = true;
                    }
                }
                // save to disk
                SaveWisaSchoolsToJSON();
            }
        }

        public async Task ReloadWisaClassgroups()
        {
            // check date
            DateTime workDate = DateTime.Now;

            // reload list of classes
            AccountApi.Wisa.ClassGroupManager.Clear();
            foreach (var school in AccountApi.Wisa.SchoolManager.All)
            {
                if (school.IsActive)
                {
                    foreach(var rule in WisaImportRules)
                    {
                        if(rule.Rule == Rule.WI_MarkAsVirtual && rule.GetConfig(0) == school.Name)
                        {
                            workDate = WisaWorkDateNow ? DateTime.Now : WisaWorkDate;
                        }
                    }

                    bool success = await AccountApi.Wisa.ClassGroupManager.AddSchool(school, workDate);
                    if (!success) return;
                }
            }
            AccountApi.Wisa.ClassGroupManager.ApplyImportRules(WisaImportRules.ToList());
            AccountApi.Wisa.ClassGroupManager.Sort();
            lastWisaClassgroupSync = DateTime.Now;

            SaveWisaClassGroupsToJSON();
        }

        public IRule AddWisaImportRule(Rule rule)
        {
            IRule newRule = null;

            switch(rule)
            {
                case Rule.WI_ReplaceInstitution: newRule = new AccountApi.Rules.ReplaceInstitute(); break;
                case Rule.WI_DontImportClass: newRule = new AccountApi.Rules.DontImportClass(); break;
                case Rule.WI_MarkAsVirtual: newRule = new AccountApi.Rules.MarkAsVirtual(); break;
            }

            if(newRule != null)
            {
                WisaImportRules.Add(newRule);
                ConfigChanged = true;
            }
            return newRule;
        }

        public async Task ReloadWisaStudents()
        {
            // check date
            DateTime workDate = DateTime.Now;

            // reload list of classes
            AccountApi.Wisa.Students.Clear();
            foreach (var school in AccountApi.Wisa.SchoolManager.All)
            {
                if (school.IsActive)
                {
                    //foreach (var rule in WisaImportRules)
                    //{
                    //    if (rule.Rule == Rule.WI_MarkAsVirtual && rule.GetConfig(0) == school.Name)
                    //    {
                            workDate = WisaWorkDateNow ? DateTime.Now : WisaWorkDate;
                    //    }
                    //}

                    bool success = await AccountApi.Wisa.Students.AddSchool(school, workDate);
                    if (!success) return;
                }
            }

            // remove students in discarded classgroups from this list
            for(int i = AccountApi.Wisa.Students.All.Count - 1; i >= 0; i--)
            {
                foreach(var rule in WisaImportRules)
                {
                    if(rule.Rule == Rule.WI_DontImportClass && rule.GetConfig(0) == AccountApi.Wisa.Students.All[i].ClassGroup)
                    {
                        AccountApi.Wisa.Students.All.RemoveAt(i);
                        break;
                    }
                }
            }

            AccountApi.Wisa.Students.Sort();
            lastWisaAccountSync = DateTime.Now;

            SaveWisaStudentsToJSON();
        }

        public void SaveWisaSchoolsToJSON()
        {
            var json = AccountApi.Wisa.SchoolManager.ToJson();
            var location = Path.Combine(appFolder, wisaSchoolsFile);
            File.WriteAllText(location, json.ToString());
        }

        public void SaveWisaClassGroupsToJSON()
        {
            var json = AccountApi.Wisa.ClassGroupManager.ToJson();
            json["lastSync"] = LastWisaClassgroupSync;

            var location = Path.Combine(appFolder, wisaClassFile);
            File.WriteAllText(location, json.ToString());
        }

        public void SaveWisaStudentsToJSON()
        {
            var json = AccountApi.Wisa.Students.ToJson();
            json["lastSync"] = LastWisaAccountSync;

            var location = Path.Combine(appFolder, wisaStudentsFile);
            File.WriteAllText(location, json.ToString());
        }
    }
}
