using AbstractAccountApi;
using AccountApi;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager
{
    public sealed partial class Data
    {
        private DateTime lastSmartschoolAccountSync;
        public DateTime LastSmartschoolAccountSync => lastSmartschoolAccountSync;

        public ObservableCollection<IRule> SmartschoolImportRules { get; set; } = new ObservableCollection<IRule>();

        public IGroup SmartschoolGroups => AccountApi.Smartschool.GroupManager.Root;

        const string smartschoolGroupsFile = "smartschoolGroups.json";

        private void LoadSmartschoolConfig(JObject obj)
        {
            smartschoolURI = obj.ContainsKey("uri") ? obj["uri"].ToString() : "";
            smartschoolPassphrase = obj.ContainsKey("passphrase") ? obj["passphrase"].ToString() : "";
            smartschoolTestUser = obj.ContainsKey("testuser") ? obj["testuser"].ToString() : "";
            if (obj.ContainsKey("connectionTested")) {
                smartschoolConnectionTested = obj["connectionTested"].ToObject <ConfigState>();
            } else
            {
                smartschoolConnectionTested = ConfigState.Failed;
            }

            smartschoolStudentGroup = obj.ContainsKey("studentGroup") ? obj["studentGroup"].ToString() : "";
            smartschoolStaffGroup = obj.ContainsKey("staffGroup") ? obj["staffGroup"].ToString() : "";

            smartschoolUseGrades = obj.ContainsKey("useGrades") ? obj["useGrades"].ToObject<bool>() : false;
            if(obj.ContainsKey("grades"))
            {
                var grades = (obj["grades"] as JArray);
                smartschoolGrades[0] = grades[0].ToString();
                smartschoolGrades[1] = grades[1].ToString();
                smartschoolGrades[2] = grades[2].ToString();
            }

            smartschoolUseYears = obj.ContainsKey("useYears") ? obj["useYears"].ToObject<bool>() : false;
            if(obj.ContainsKey("years"))
            {
                var years = (obj["years"] as JArray);
                for(int i = 0; (i < years.Count) && (i < smartschoolYears.Count()); i++)
                {
                    smartschoolYears[i] = years[i].ToString();
                }
            }

            if(obj.ContainsKey("importRules"))
            {
                var arr = obj["importRules"] as JArray;
                foreach(var item in arr)
                {
                    var data = item as JObject;
                    Rule rule = (Rule)data["Rule"].ToObject(typeof(Rule));
                    switch(rule)
                    {
                        case Rule.SS_DiscardGroup: SmartschoolImportRules.Add(new AccountApi.Rules.DiscardSmartschoolGroup(data)); break;
                        case Rule.SS_NoSubGroups: SmartschoolImportRules.Add(new AccountApi.Rules.NoSmartschoolSubGroups(data)); break;
                    }
                }
            }

            AccountApi.Smartschool.Connector.StudentPath = smartschoolStudentGroup;
            AccountApi.Smartschool.Connector.StaffPath = smartschoolStaffGroup;
        }

        private JObject SaveSmartschoolConfig()
        {
            JObject result = new JObject
            {
                ["uri"] = smartschoolURI,
                ["passphrase"] = smartschoolPassphrase,
                ["testuser"] = smartschoolTestUser,
                ["connectionTested"] = smartschoolConnectionTested.ToString(),
                ["studentGroup"] = smartschoolStudentGroup,
                ["staffGroup"] = smartschoolStaffGroup,
                ["useGrades"] = smartschoolUseGrades,
                ["useYears"] = smartschoolUseYears,
                ["grades"] = new JArray(smartschoolGrades),
                ["years"] = new JArray(smartschoolYears)
            };

            if (SmartschoolImportRules.Count > 0)
            {
                var arr = new JArray();
                foreach(var rule in SmartschoolImportRules)
                {
                    arr.Add(rule.ToJson());
                }
                result["importRules"] = arr;
            }
            return result;
        }

        private void LoadSmartschoolFileContent()
        {
            SetSmartschoolCredentials();

            var smartschoolGroupsLocation = Path.Combine(appFolder, smartschoolGroupsFile);
            if(File.Exists(smartschoolGroupsLocation))
            {
                string content = File.ReadAllText(smartschoolGroupsLocation);
                var newObj = JObject.Parse(content);
                AccountApi.Smartschool.GroupManager.FromJson(newObj);
                lastSmartschoolAccountSync = newObj.ContainsKey("lastSync") ? Convert.ToDateTime(newObj["lastSync"]) : DateTime.MinValue;
            }
        }

        private AccountApi.ConfigState smartschoolConnectionTested;

        public AccountApi.ConfigState SmartschoolConnectionTested
        {
            get { return smartschoolConnectionTested; }
            set {
                smartschoolConnectionTested = value;
                Properties.Settings.Default.SmartschoolConnectionTested = value;
                ConfigChanged = true;
            }
        }


        private string smartschoolURI;

        public string SmartschoolURI
        {
            get { return smartschoolURI; }
            set {
                smartschoolURI = value.Trim();
                SmartschoolConnectionTested = ConfigState.Unknown;
            }
        }

        private string smartschoolPassphrase;

        public string SmartschoolPassphrase
        {
            get { return smartschoolPassphrase; }
            set {
                smartschoolPassphrase = value.Trim();
                SmartschoolConnectionTested = ConfigState.Unknown;
            }
        }

        private string smartschoolTestUser;

        public string SmartschoolTestUser
        {
            get { return smartschoolTestUser; }
            set {
                smartschoolTestUser = value.Trim();
                SmartschoolConnectionTested = ConfigState.Unknown;
            }
        }

        private string smartschoolStudentGroup;

        public string SmartschoolStudentGroup
        {
            get { return smartschoolStudentGroup; }
            set {
                smartschoolStudentGroup = value.Trim();
                AccountApi.Smartschool.Connector.StudentPath = smartschoolStudentGroup;
                ConfigChanged = true;
            }
        }

        private string smartschoolStaffGroup;

        public string SmartschoolStaffGroup
        {
            get { return smartschoolStaffGroup; }
            set {
                smartschoolStaffGroup = value.Trim();
                AccountApi.Smartschool.Connector.StaffPath = smartschoolStaffGroup;
                ConfigChanged = true;
            }
        }

        private bool smartschoolUseGrades;

        public bool SmartschoolUseGrades
        {
            get { return smartschoolUseGrades; }
            set {
                smartschoolUseGrades = value;
                UpdateSmartschoolGrades();
            }
        }

        private string[] smartschoolGrades = new string[3];
        public string SmartschoolGrade1 { get => smartschoolGrades[0]; set { smartschoolGrades[0] = value.Trim(); UpdateSmartschoolGrades(); } }
        public string SmartschoolGrade2 { get => smartschoolGrades[1]; set { smartschoolGrades[1] = value.Trim(); UpdateSmartschoolGrades(); } }
        public string SmartschoolGrade3 { get => smartschoolGrades[2]; set { smartschoolGrades[2] = value.Trim(); UpdateSmartschoolGrades(); } }

        private void UpdateSmartschoolGrades()
        {
            var grades = new StringCollection();
            grades.AddRange(smartschoolGrades);
            ConfigChanged = true;

            if (smartschoolUseGrades)
            {
                AccountApi.Smartschool.Connector.StudentGrade = smartschoolGrades;
            }
            else
            {
                AccountApi.Smartschool.Connector.StudentGrade = new string[0];
            }
        }

        private bool smartschoolUseYears;

        public bool SmartschoolUseYears
        {
            get { return smartschoolUseYears; }
            set
            {
                smartschoolUseYears = value;
                UpdateSmartschoolYears();
            }
        }

        private string[] smartschoolYears = new string[7];
        public string SmartschoolYear1 { get => smartschoolYears[0]; set { smartschoolYears[0] = value.Trim(); UpdateSmartschoolYears(); } }
        public string SmartschoolYear2 { get => smartschoolYears[1]; set { smartschoolYears[1] = value.Trim(); UpdateSmartschoolYears(); } }
        public string SmartschoolYear3 { get => smartschoolYears[2]; set { smartschoolYears[2] = value.Trim(); UpdateSmartschoolYears(); } }
        public string SmartschoolYear4 { get => smartschoolYears[3]; set { smartschoolYears[3] = value.Trim(); UpdateSmartschoolYears(); } }
        public string SmartschoolYear5 { get => smartschoolYears[4]; set { smartschoolYears[4] = value.Trim(); UpdateSmartschoolYears(); } }
        public string SmartschoolYear6 { get => smartschoolYears[5]; set { smartschoolYears[5] = value.Trim(); UpdateSmartschoolYears(); } }
        public string SmartschoolYear7 { get => smartschoolYears[6]; set { smartschoolYears[6] = value.Trim(); UpdateSmartschoolYears(); } }

        private void UpdateSmartschoolYears()
        {
            var years = new StringCollection();
            years.AddRange(smartschoolYears);
            ConfigChanged = true;

            if (smartschoolUseYears)
            {
                AccountApi.Smartschool.Connector.StudentYear = smartschoolYears;
            }
            else
            {
                AccountApi.Smartschool.Connector.StudentYear = new string[0];
            }
        }

        public void SetSmartschoolCredentials()
        {
            AccountApi.Smartschool.Connector.Init(
                SmartschoolURI, SmartschoolPassphrase, MainWindow.Instance.Log
            );
        }

        public async Task<bool> TestSmartschoolConnection()
        {
            var account = new AccountApi.Smartschool.Account
            {
                UID = SmartschoolTestUser
            };

            bool result = await AccountApi.Smartschool.AccountManager.Load(account);
            if(result)
            {
                MainWindow.Instance.Log.AddMessage(Origin.Smartschool, "Connection Succeeded");
            } else
            {
                MainWindow.Instance.Log.AddError(Origin.Smartschool, "Connection Failed");
            }
            return result;
        }

        public IRule AddSmartschoolImportRule(Rule rule)
        {
            IRule newRule = null;

            switch(rule)
            {
                case Rule.SS_DiscardGroup: newRule = new AccountApi.Rules.DiscardSmartschoolGroup(); break;
                case Rule.SS_NoSubGroups: newRule = new AccountApi.Rules.NoSmartschoolSubGroups(); break;
            }

            if (newRule != null)
            {
                SmartschoolImportRules.Add(newRule);
                ConfigChanged = true;
            }
            return newRule;
        }

        public async Task ReloadSmartschool()
        {
            await AccountApi.Smartschool.GroupManager.Reload();
            AccountApi.Smartschool.GroupManager.Root.ApplyImportRules(SmartschoolImportRules.ToList());

            // load students accounts
            IGroup students = AccountApi.Smartschool.GroupManager.Root.Find("Leerlingen");
            if(students != null)
            {
                List<IGroup> groups = new List<IGroup>();
                students.GetTreeAsList(groups);

                foreach(var group in groups)
                {
                    await group.LoadAccounts();
                }
            }

            // load staff accounts
            IGroup staff = AccountApi.Smartschool.GroupManager.Root.Find("Personeel");
            if(staff != null)
            {
                List<IGroup> groups = new List<IGroup>();
                staff.GetTreeAsList(groups);

                foreach (var group in groups)
                {
                    await group.LoadAccounts();
                }
            }
            AccountApi.Smartschool.GroupManager.Root.Sort();
            lastSmartschoolAccountSync = DateTime.Now;

            SaveSmartschoolAccount();
        }

        public void SaveSmartschoolAccount()
        {
            var json = AccountApi.Smartschool.GroupManager.ToJson(true);
            json["lastSync"] = LastSmartschoolAccountSync;

            var location = Path.Combine(appFolder, smartschoolGroupsFile);
            File.WriteAllText(location, json.ToString());
        }
    }
}
