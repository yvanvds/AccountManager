using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using AccountManager.Utils;
using AccountApi;
using System.Collections.ObjectModel;

namespace AccountManager.State.Wisa
{
    public class WisaState : AbstractState
    {

        public ConfigValue<ConnectionState> Connection;
        public ConfigValue<string> Server;
        public ConfigValue<string> Port;
        public ConfigValue<string> Database;
        public ConfigValue<string> User;
        public ConfigValue<string> Password;
        public ConfigValue<DateTime> WorkDate;
        public ConfigValue<bool> WorkDateIsNow;
        public ConfigValue<DateTime> WorkDateVirtual;
        public ConfigValue<bool> WorkDateVirtualIsNow;

        public ObservableCollection<IRule> ImportRules { get; set; } = new ObservableCollection<IRule>();

        public WisaSchools Schools { get; } = new WisaSchools();
        public WisaGroups Groups { get; } = new WisaGroups();
        public WisaStudents Students { get; } = new WisaStudents();
        public WisaStaff Staff { get; } = new WisaStaff();

        public WisaState()
        {
            Server = new ConfigValue<string>("server", "", UpdateObservers, UpdateConnectionState);
            Port = new ConfigValue<string>("port", "", UpdateObservers, UpdateConnectionState);
            Database = new ConfigValue<string>("database", "", UpdateObservers, UpdateConnectionState);
            User = new ConfigValue<string>("user", "", UpdateObservers, UpdateConnectionState);
            Password = new ConfigValue<string>("password", "", UpdateObservers, UpdateConnectionState);
            Connection = new ConfigValue<ConnectionState>("connectionTested", ConnectionState.Unknown, UpdateObservers);
            
            WorkDateIsNow = new ConfigValue<bool>("workDateNow", true, UpdateObservers);
            WorkDate = new ConfigValue<DateTime>("workData", DateTime.Now, UpdateObservers);
            WorkDateVirtualIsNow = new ConfigValue<bool>(" workDateVirtualNow", true, UpdateObservers);
            WorkDateVirtual = new ConfigValue<DateTime>("workDateVirtual", DateTime.Now, UpdateObservers);
        }

        public override void LoadConfig(JObject obj)
        {
            Server.Load(obj);
            Port.Load(obj);
            Database.Load(obj);
            User.Load(obj);
            Password.Load(obj);
            Connection.Load(obj);
            WorkDateIsNow.Load(obj);
            WorkDate.Load(obj);
            if (WorkDateIsNow.Value)
            {
                WorkDate.Value = DateTime.Now;
            }
            WorkDateVirtualIsNow.Load(obj);
            WorkDateVirtual.Load(obj);
            if(WorkDateVirtualIsNow.Value)
            {
                WorkDateVirtual.Value = DateTime.Now;
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
                        case Rule.WI_ReplaceInstitution: ImportRules.Add(new AccountApi.Rules.ReplaceInstitute(data)); break;
                        case Rule.WI_DontImportClass: ImportRules.Add(new AccountApi.Rules.DontImportClass(data)); break;
                        case Rule.WI_MarkAsVirtual: ImportRules.Add(new AccountApi.Rules.MarkAsVirtual(data)); break;
                    }
                }
            }

            UpdateObservers();
        }

        public override JObject SaveConfig()
        {
            JObject result = new JObject();

            Server.Save(ref result);
            Port.Save(ref result);
            Database.Save(ref result);
            User.Save(ref result);
            Password.Save(ref result);
            WorkDate.Save(ref result);
            WorkDateIsNow.Save(ref result);
            WorkDateVirtual.Save(ref result);
            WorkDateVirtualIsNow.Save(ref result);

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
            await Schools.Load().ConfigureAwait(false);
            await Groups.Load().ConfigureAwait(false);
            await Students.Load().ConfigureAwait(false);
            await Staff.Load().ConfigureAwait(false);
        }

        public override void LoadLocalContent()
        {
            Schools.LoadFromJson();
            Groups.LoadFromJson();
            Students.LoadFromJson();
            Staff.LoadFromJson();
        }

        public override void SaveContent()
        {
            Schools.SaveToJson();
            Groups.SaveToJson();
            Students.SaveToJson();
            Staff.SaveToJson();
        }

        public void Connect()
        {
            int port = 0;
            try
            {
                port = Convert.ToInt32(Port.Value);
            }
            catch (Exception)
            {
                MainWindow.Instance.Log.AddError(Origin.Wisa, "Port should be a number");
                return;
            }


            AccountApi.Wisa.Connector.Init(
                Server.Value, port, User.Value, Password.Value, Database.Value, MainWindow.Instance.Log
            );
        }

        public IRule AddimportRule(Rule rule)
        {
            IRule newRule = null;

            switch (rule)
            {
                case Rule.WI_ReplaceInstitution: newRule = new AccountApi.Rules.ReplaceInstitute(); break;
                case Rule.WI_DontImportClass: newRule = new AccountApi.Rules.DontImportClass(); break;
                case Rule.WI_MarkAsVirtual: newRule = new AccountApi.Rules.MarkAsVirtual(); break;
                case Rule.WI_DontImportUser: newRule = new AccountApi.Rules.DontImportUserFromWisa(); break;
            }

            if (newRule != null)
            {
                ImportRules.Add(newRule);
            }
            return newRule;
        }

        public bool IsSchoolVirtual(AccountApi.Wisa.School school)
        {
            foreach(var rule in ImportRules)
            {
                if (rule.Rule == Rule.WI_MarkAsVirtual)
                {
                    return (rule as AccountApi.Rules.MarkAsVirtual).ShouldApply(school);
                }
            }
            return false;
        }


        public void UpdateConnectionState(ConnectionState state)
        {
            Connection.Value = state;
        }

    }
}

