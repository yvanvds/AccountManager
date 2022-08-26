using AccountApi;
using AccountManager.Utils;
using AccountManager.Views.Dialogs;
using MaterialDesignThemes.Wpf;
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
        public ConfigValue<string> IPAddress;

        public ConfigValue<bool> UseGrades;
        public ConfigValue<bool> UseYears;

        public ConfigValue<string> Username;

        private string password = "";
        private bool passwordOK = false;
        private bool connected = false;

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
            IPAddress = new ConfigValue<string>("ipAddress", "", UpdateObservers, UpdateConnectionState);

            UseGrades = new ConfigValue<bool>("useGrades", false, UpdateObservers);
            UseYears = new ConfigValue<bool>("useYears", false, UpdateObservers);

            Username = new ConfigValue<string>("username", "", UpdateObservers, UpdateConnectionState);
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
            IPAddress.Load(obj);
            Username.Load(obj);

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
            IPAddress.Save(ref result);
            Connection.Save(ref result);
            UseGrades.Save(ref result);
            UseYears.Save(ref result);
            Username.Save(ref result);
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
            if(await Connect().ConfigureAwait(false))
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

        public async Task<bool> Connect()
        {
            if (connected) return true;

            if(!passwordOK)
            {
                AD_AskForPassword dialog = new AD_AskForPassword(Username.Value);
                string dialogResult = (string) await  DialogHost.Show(dialog, "RootDialog").ConfigureAwait(false);

                if (dialogResult.Equals("true", StringComparison.CurrentCultureIgnoreCase))
                {
                    if (dialog.Username != Username.Value)
                    {
                        Username.Value = dialog.Username;
                        SaveConfig();
                    }
                    
                    password = dialog.Password;
                } else
                {
                    MainWindow.Instance.Log.AddError(Origin.Directory, "Not Connected");
                    return false;
                }
            }

            AccountApi.Directory.Connector.AzureDomain = AzureDomain.Value;
            bool result =  AccountApi.Directory.Connector.Init(
                Domain.Value, IPAddress.Value, AccountRoot.Value, ClassesRoot.Value, StudentRoot.Value, StaffRoot.Value, State.App.Instance.Settings.SchoolPrefix.Value, Username.Value, password, MainWindow.Instance.Log
            );

            if (result)
            {
                passwordOK = true;
                connected = true;

            } else
            {
                MainWindow.Instance.Log.AddError(Origin.Directory, "Not Connected");
            }

            return result;
        }

        public async Task ReloadGroups()
        {
            bool connected = await Connect().ConfigureAwait(false);
            if (connected)
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
