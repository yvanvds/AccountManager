using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    class ModifyDirectoryData : AccountAction
    {
        public enum Fields
        {
            CommonName,
        }

        public List<Fields> List = new List<Fields>();

        public new string Description
        {
            get
            {
                string result = "De volgende velden zijn niet up to date in active directory: ";
                foreach (var field in List)
                {
                    result += field.ToString() + ", ";
                }
                result = result.Remove(result.Count() - 2, 2);
                result += ". Ze kunnen automatisch aangepast worden.";
                return result;
            }
        }

        public ModifyDirectoryData() : base(
            "Wijzig de Active Directory Gebruiker",
            "...",
            true, true)
        {

        }

        public override async Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            bool connected = await State.App.Instance.AD.Connect().ConfigureAwait(false);
            if (!connected) return;

            Indicator = true;

            await Task.Run(() =>
            {
                foreach (var field in List)
                {
                    switch (field)
                    {
                        case Fields.CommonName:

                            linkedAccount.Directory.Account.CN = linkedAccount.Directory.Account.DesiredCN();
                            break;
                    }
                }
            }).ConfigureAwait(false);
            MainWindow.Instance.Log.AddMessage(AccountApi.Origin.Directory, "Actie uitgevoerd voor " + linkedAccount.Directory.Account.FullName);

            Indicator = false;
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            var action = new ModifyDirectoryData();
            if (account.Directory.Account.CN != account.Directory.Account.DesiredCN())
            {
                action.List.Add(Fields.CommonName);
            }

            if (action.List.Count > 0)
            {
                account.Directory.FlagWarning();
                account.Actions.Add(action);
                account.OK = false;
            }
        }
    }
}
