using AccountApi;
using AccountManager.Utils;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Smartschool
{
    public class SmartschoolState : AbstractState
    {
        public ConfigValue<ConnectionState> Connection;
        public ConfigValue<string> Uri;
        public ConfigValue<string> Passphrase;
        public ConfigValue<string> TestUser;
        public ConfigValue<string> StudentGroup;
        public ConfigValue<string> StaffGroup;
        public ConfigValue<bool> UseGrades;
        public ConfigValue<bool> UseYears;

        public ObservableCollection<IRule> ImportRules { get; set; } = new ObservableCollection<IRule>();

        private string[] grades = new string[3];
        public string Grade1 { get => grades[0]; set { grades[0] = value.Trim(); } }
        public string Grade2 { get => grades[1]; set { grades[1] = value.Trim(); } }
        public string Grade3 { get => grades[2]; set { grades[2] = value.Trim(); } }

        private string[] years = new string[7];
        public string Year1 { get => years[0]; set { years[0] = value.Trim();  } }
        public string Year2 { get => years[1]; set { years[1] = value.Trim(); } }
        public string Year3 { get => years[2]; set { years[2] = value.Trim(); } }
        public string Year4 { get => years[3]; set { years[3] = value.Trim(); } }
        public string Year5 { get => years[4]; set { years[4] = value.Trim(); } }
        public string Year6 { get => years[5]; set { years[5] = value.Trim(); } }
        public string Year7 { get => years[6]; set { years[6] = value.Trim(); } }

        public SmartschoolGroups Groups = new SmartschoolGroups();

        public SmartschoolState()
        {
            Connection = new ConfigValue<ConnectionState>("connectionTested", ConnectionState.Unknown, UpdateObservers);
            Uri = new ConfigValue<string>("uri", "", UpdateObservers, UpdateConnectionState);
            Passphrase = new ConfigValue<string>("passphrase", "", UpdateObservers, UpdateConnectionState);
            TestUser = new ConfigValue<string>("testuser", "", UpdateObservers, UpdateConnectionState);
            StudentGroup = new ConfigValue<string>("studentGroup", "", UpdateObservers, UpdateConnectionState);
            StaffGroup = new ConfigValue<string>("staffGroup", "", UpdateObservers, UpdateConnectionState);
            UseGrades = new ConfigValue<bool>("useGrades", false, UpdateObservers, UpdateConnectionState);
            UseYears = new ConfigValue<bool>("useYears", false, UpdateObservers, UpdateConnectionState);
        }

        public override void LoadConfig(JObject obj)
        {
            Connection.Load(obj);
            Uri.Load(obj);
            Passphrase.Load(obj);
            TestUser.Load(obj);
            StudentGroup.Load(obj);
            StaffGroup.Load(obj);
            UseGrades.Load(obj);
            UseYears.Load(obj);

            if (obj.ContainsKey("grades"))
            {
                var grades = (obj["grades"] as JArray);
                for (int i = 0; i < grades.Count && i < this.grades.Count(); i++)
                {
                    this.grades[i] = grades[i].ToString();
                }
            }

            if (obj.ContainsKey("years"))
            {
                var years = (obj["years"] as JArray);
                for (int i = 0; i < years.Count && i < this.years.Count(); i++)
                {
                    this.years[i] = years[i].ToString();
                }
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
                        case Rule.SS_DiscardGroup: ImportRules.Add(new AccountApi.Rules.DiscardSmartschoolGroup(data)); break;
                        case Rule.SS_NoSubGroups: ImportRules.Add(new AccountApi.Rules.NoSmartschoolSubGroups(data)); break;
                    }
                }
            }
        }

        public override JObject SaveConfig()
        {
            JObject result = new JObject();
            Connection.Save(ref result);
            Uri.Save(ref result);
            Passphrase.Save(ref result);
            TestUser.Save(ref result);
            StudentGroup.Save(ref result);
            StaffGroup.Save(ref result);
            UseGrades.Save(ref result);
            UseYears.Save(ref result);
            result["grades"] = new JArray(grades);
            result["years"] = new JArray(years);

            if (ImportRules.Count > 0)
            {
                var arr = new JArray();
                foreach (var rule in ImportRules)
                {
                    arr.Add(rule.ToJson());
                }
                result["importRules"] = arr;
            }

            return result;
        }


        public override async Task LoadContent()
        {
            Connect();
            await Groups.Load();
        }

        public override void LoadLocalContent()
        {
            Connect();
            Groups.LoadFromJson();
        }

        

        public override void SaveContent()
        {
            Groups.SaveToJson();
        }

        public void UpdateConnectionState(ConnectionState state)
        {
            Connection.Value = state;
        }

        public void Connect()
        {
            AccountApi.Smartschool.Connector.StudentPath = StudentGroup.Value;
            AccountApi.Smartschool.Connector.StaffPath = StaffGroup.Value;
            AccountApi.Smartschool.Connector.StudentYear = years;
            AccountApi.Smartschool.Connector.StudentGrade = grades;

            AccountApi.Smartschool.Connector.Init(
                Uri.Value, Passphrase.Value, MainWindow.Instance.Log
            );
        }

        public IRule AddImportRule(Rule rule)
        {
            IRule newRule = null;

            switch (rule)
            {
                case Rule.SS_DiscardGroup: newRule = new AccountApi.Rules.DiscardSmartschoolGroup(); break;
                case Rule.SS_NoSubGroups: newRule = new AccountApi.Rules.NoSmartschoolSubGroups(); break;
            }

            if (newRule != null)
            {
                ImportRules.Add(newRule);
            }
            return newRule;
        }
    }
}
