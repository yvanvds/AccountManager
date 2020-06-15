using AccountApi;
using AccountManager.Utils;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.AD
{
    public class ADState : AbstractState
    {
        public ConfigValue<ConnectionState> Connection;
        public ConfigValue<string> Domain;
        public ConfigValue<string> AccountRoot;
        public ConfigValue<string> ClassesRoot;
        public ConfigValue<string> StudentRoot;
        public ConfigValue<string> StaffRoot;
        public ConfigValue<string> AzureDomain;
        public ConfigValue<bool> CheckHomeDirs;

        public ConfigValue<bool> UseGrades;
        public ConfigValue<bool> UseYears;

        public ObservableCollection<IRule> ImportRules { get; set; } = new ObservableCollection<IRule>();

        private string[] grades = new string[3];
        public string Grade1 { get => grades[0]; set { grades[0] = value.Trim(); updateGrades(); } }
        public string Grade2 { get => grades[1]; set { grades[1] = value.Trim(); updateGrades(); } }
        public string Grade3 { get => grades[2]; set { grades[2] = value.Trim(); updateGrades(); } }

        private string[] years = new string[7];
        public string Year1 { get => years[0]; set { years[0] = value.Trim(); updateYears(); } }
        public string Year2 { get => years[1]; set { years[1] = value.Trim(); updateYears(); } }
        public string Year3 { get => years[2]; set { years[2] = value.Trim(); updateYears(); } }
        public string Year4 { get => years[3]; set { years[3] = value.Trim(); updateYears(); } }
        public string Year5 { get => years[4]; set { years[4] = value.Trim(); updateYears(); } }
        public string Year6 { get => years[5]; set { years[5] = value.Trim(); updateYears(); } }
        public string Year7 { get => years[6]; set { years[6] = value.Trim(); updateYears(); } }

        public ADGroups Groups = new ADGroups();
        public ADAccounts Accounts = new ADAccounts();

        public ADState()
        {
            Domain = new ConfigValue<string>("domain", "", UpdateObservers, UpdateConnectionState);
            AccountRoot = new ConfigValue<string>("accounts", "", UpdateObservers, UpdateConnectionState);
            ClassesRoot = new ConfigValue<string>("classes", "", UpdateObservers, UpdateConnectionState);
            StudentRoot = new ConfigValue<string>("students", "", UpdateObservers, UpdateConnectionState);
            StaffRoot = new ConfigValue<string>("staff", "", UpdateObservers, UpdateConnectionState);
            AzureDomain = new ConfigValue<string>("azure", "", UpdateObservers);
            Connection = new ConfigValue<ConnectionState>("connectionTested", ConnectionState.Unknown, UpdateObservers);
            CheckHomeDirs = new ConfigValue<bool>("checkHomeDirs", false, UpdateObservers);

            UseGrades = new ConfigValue<bool>("useGrades", false, UpdateObservers);
            UseYears = new ConfigValue<bool>("useYears", false, UpdateObservers);
        }

        public override void LoadConfig(JObject obj)
        {
            Domain.Load(obj);
            AccountRoot.Load(obj);
            ClassesRoot.Load(obj);
            StudentRoot.Load(obj);
            StaffRoot.Load(obj);
            AzureDomain.Load(obj);
            Connection.Load(obj);
            UseGrades.Load(obj);
            UseYears.Load(obj);

            if (obj.ContainsKey("grades"))
            {
                var grades = (obj["grades"] as JArray);
                for (int i = 0; i < grades.Count && i < this.grades.Length; i++)
                {
                    this.grades[i] = grades[i].ToString();
                }
            }

            if (obj.ContainsKey("years"))
            {
                var years = (obj["years"] as JArray);
                for (int i = 0; i < years.Count && i < this.years.Length; i++)
                {
                    this.years[i] = years[i].ToString();
                }
            }

            updateGrades();
            updateYears();

            if (obj.ContainsKey("importRules"))
            {
                var arr = obj["importRules"] as JArray;
                foreach(var item in arr)
                {
                    var data = item as JObject;
                    Rule rule = (Rule)data["Rule"].ToObject(typeof(Rule));
                    switch (rule)
                    {
                        case Rule.AD_DontImportUser: ImportRules.Add(new AccountApi.Rules.DontImportUserFromAD(data)); break;
                    }
                }
            }
        }

        public override JObject SaveConfig()
        {
            JObject result = new JObject();

            Domain.Save(ref result);
            AccountRoot.Save(ref result);
            ClassesRoot.Save(ref result);
            StudentRoot.Save(ref result);
            StaffRoot.Save(ref result);
            AzureDomain.Save(ref result);
            Connection.Save(ref result);
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
            if(Connect())
            {
                await Groups.Load().ConfigureAwait(false);
                await Accounts.Load().ConfigureAwait(false);
            }
        }

        public override void LoadLocalContent()
        {
            Groups.LoadFromJson();
            Accounts.LoadFromJson();
        }

        public override void SaveContent()
        {
            Groups.SaveToJson();
            Accounts.SaveToJson();
        }

        public bool Connect()
        {
            AccountApi.Directory.Connector.AzureDomain = AzureDomain.Value;
            return AccountApi.Directory.Connector.Init(
                Domain.Value, AccountRoot.Value, ClassesRoot.Value, StudentRoot.Value, StaffRoot.Value, MainWindow.Instance.Log
            );
        }

        public async Task ReloadGroups()
        {
            if (Connect())
            {
                await Groups.Load().ConfigureAwait(false);
            }
        }

        public IRule AddimportRule(Rule rule)
        {
            IRule newRule = null;

            switch (rule)
            {
                case Rule.AD_DontImportUser: newRule = new AccountApi.Rules.DontImportUserFromAD(); break;
            }

            if (newRule != null)
            {
                ImportRules.Add(newRule);
            }
            return newRule;
        }

        public void UpdateConnectionState(ConnectionState state)
        {
            Connection.Value = state;
        }

        private void updateGrades()
        {
            if (UseGrades.Value)
            {
                AccountApi.Directory.Connector.StudentGrade = grades;
            }
            else
            {
                AccountApi.Directory.Connector.StudentGrade = Array.Empty<string>();
            }

            UpdateObservers();
        }

        private void updateYears()
        {
            if (UseYears.Value)
            {
                AccountApi.Directory.Connector.StudentYear = years;
            }
            else
            {
                AccountApi.Directory.Connector.StudentYear = Array.Empty<string>();
            }

            UpdateObservers();
        }
    }
}
