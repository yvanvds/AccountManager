using AbstractAccountApi;
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
        public ObservableCollection<IRule> SmartschoolImportRules { get; set; } = new ObservableCollection<IRule>();

        public IGroup SmartschoolGroups => SmartschoolApi.GroupManager.Root;

        const string smartschoolGroupsFile = "smartschoolGroups.json";

        private void loadSmartschoolConfig(JObject obj)
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
                        case Rule.SS_DiscardGroup: SmartschoolImportRules.Add(new SmartschoolApi.Rules.DiscardGroup(data)); break;
                        case Rule.SS_NoSubGroups: SmartschoolImportRules.Add(new SmartschoolApi.Rules.NoSubGroups(data)); break;
                    }
                }
            }

            SmartschoolApi.Connector.StudentPath = smartschoolStudentGroup;
            SmartschoolApi.Connector.StaffPath = smartschoolStaffGroup;
        }

        private JObject saveSmartschoolConfig()
        {
            JObject result = new JObject();
            result["uri"] = smartschoolURI;
            result["passphrase"] = smartschoolPassphrase;
            result["testuser"] = smartschoolTestUser;
            result["connectionTested"] = smartschoolConnectionTested.ToString();
            result["studentGroup"] = smartschoolStudentGroup;
            result["staffGroup"] = smartschoolStaffGroup;
            result["useGrades"] = smartschoolUseGrades;
            result["useYears"] = smartschoolUseYears;
            result["grades"] = new JArray(smartschoolGrades);
            result["years"] = new JArray(smartschoolYears);

            if(SmartschoolImportRules.Count > 0)
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

        private void loadSmartschoolFileContent()
        {
            SetSmartschoolCredentials();

            var smartschoolGroupsLocation = Path.Combine(appFolder, smartschoolGroupsFile);
            if(File.Exists(smartschoolGroupsLocation))
            {
                string content = File.ReadAllText(smartschoolGroupsLocation);
                var newObj = JObject.Parse(content);
                SmartschoolApi.GroupManager.FromJson(newObj);
            }
        }

        private AbstractAccountApi.ConfigState smartschoolConnectionTested;

        public AbstractAccountApi.ConfigState SmartschoolConnectionTested
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
                SmartschoolApi.Connector.StudentPath = smartschoolStudentGroup;
                ConfigChanged = true;
            }
        }

        private string smartschoolStaffGroup;

        public string SmartschoolStaffGroup
        {
            get { return smartschoolStaffGroup; }
            set {
                smartschoolStaffGroup = value.Trim();
                SmartschoolApi.Connector.StaffPath = smartschoolStaffGroup;
                ConfigChanged = true;
            }
        }

        private bool smartschoolUseGrades;

        public bool SmartschoolUseGrades
        {
            get { return smartschoolUseGrades; }
            set {
                smartschoolUseGrades = value;
                updateSmartschoolGrades();
            }
        }

        private string[] smartschoolGrades = new string[3];
        public string SmartschoolGrade1 { get => smartschoolGrades[0]; set { smartschoolGrades[0] = value.Trim(); updateSmartschoolGrades(); } }
        public string SmartschoolGrade2 { get => smartschoolGrades[1]; set { smartschoolGrades[1] = value.Trim(); updateSmartschoolGrades(); } }
        public string SmartschoolGrade3 { get => smartschoolGrades[2]; set { smartschoolGrades[2] = value.Trim(); updateSmartschoolGrades(); } }

        private void updateSmartschoolGrades()
        {
            var grades = new StringCollection();
            grades.AddRange(smartschoolGrades);
            ConfigChanged = true;

            if (smartschoolUseGrades)
            {
                SmartschoolApi.Connector.StudentGrade = smartschoolGrades;
            }
            else
            {
                SmartschoolApi.Connector.StudentGrade = new string[0];
            }
        }

        private bool smartschoolUseYears;

        public bool SmartschoolUseYears
        {
            get { return smartschoolUseYears; }
            set
            {
                smartschoolUseYears = value;
                updateSmartschoolYears();
            }
        }

        private string[] smartschoolYears = new string[7];
        public string SmartschoolYear1 { get => smartschoolYears[0]; set { smartschoolYears[0] = value.Trim(); updateSmartschoolYears(); } }
        public string SmartschoolYear2 { get => smartschoolYears[1]; set { smartschoolYears[1] = value.Trim(); updateSmartschoolYears(); } }
        public string SmartschoolYear3 { get => smartschoolYears[2]; set { smartschoolYears[2] = value.Trim(); updateSmartschoolYears(); } }
        public string SmartschoolYear4 { get => smartschoolYears[3]; set { smartschoolYears[3] = value.Trim(); updateSmartschoolYears(); } }
        public string SmartschoolYear5 { get => smartschoolYears[4]; set { smartschoolYears[4] = value.Trim(); updateSmartschoolYears(); } }
        public string SmartschoolYear6 { get => smartschoolYears[5]; set { smartschoolYears[5] = value.Trim(); updateSmartschoolYears(); } }
        public string SmartschoolYear7 { get => smartschoolYears[6]; set { smartschoolYears[6] = value.Trim(); updateSmartschoolYears(); } }

        private void updateSmartschoolYears()
        {
            var years = new StringCollection();
            years.AddRange(smartschoolYears);
            ConfigChanged = true;

            if (smartschoolUseYears)
            {
                SmartschoolApi.Connector.StudentYear = smartschoolYears;
            }
            else
            {
                SmartschoolApi.Connector.StudentYear = new string[0];
            }
        }

        public void SetSmartschoolCredentials()
        {
            SmartschoolApi.Connector.Init(
                SmartschoolURI, SmartschoolPassphrase, MainWindow.Instance.Log
            );
        }

        public async Task<bool> TestSmartschoolConnection()
        {
            var account = new SmartschoolApi.Account();
            account.UID = SmartschoolTestUser;

            bool result = await SmartschoolApi.Accounts.Load(account);
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
                case Rule.SS_DiscardGroup: newRule = new SmartschoolApi.Rules.DiscardGroup(); break;
                case Rule.SS_NoSubGroups: newRule = new SmartschoolApi.Rules.NoSubGroups(); break;
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
            await SmartschoolApi.GroupManager.Reload();
            SmartschoolApi.GroupManager.Root.ApplyImportRules(SmartschoolImportRules.ToList());

            // load students accounts
            IGroup students = SmartschoolApi.GroupManager.Root.Find("Leerlingen");
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
            IGroup staff = SmartschoolApi.GroupManager.Root.Find("Personeel");
            if(staff != null)
            {
                List<IGroup> groups = new List<IGroup>();
                staff.GetTreeAsList(groups);

                foreach (var group in groups)
                {
                    await group.LoadAccounts();
                }
            }
            SmartschoolApi.GroupManager.Root.Sort();

            var json = SmartschoolApi.GroupManager.ToJson(true);
            var location = Path.Combine(appFolder, smartschoolGroupsFile);
            File.WriteAllText(location, json.ToString());
        }
    }
}
