using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    class CreateHomeDir : AccountAction
    {
        public CreateHomeDir() : base(
            "Maak de Home Directory opnieuw aan",
            "Dit maakt een home directory op de fileserver voor dit account, en stelt de toegangsrechten in. Deze actie kan een tijd duren.",
            true, true)
        {

        }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            MainWindow.Instance.Log.AddMessage(Origin.Directory, "Adding home for " + linkedAccount.Directory.Account.FullName);
            bool success = await AccountApi.Directory.AccountManager.CreateHomeDir(linkedAccount.Directory.Account).ConfigureAwait(false);
            if (success)
            {
                MainWindow.Instance.Log.AddMessage(Origin.Directory, "Added home at " + linkedAccount.Directory.Account.HomeDirectory);
            }
            else
            {
                MainWindow.Instance.Log.AddError(Origin.Directory, "Failed to add home at " + linkedAccount.Directory.Account.HomeDirectory);
            }
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (State.App.Instance.AD.CheckHomeDirs.Value == false) return;
            if (account.Directory.Account.HomeDirectory.Length > 0 && !System.IO.Directory.Exists(account.Directory.Account.HomeDirectory))
            {
                account.Directory.FlagWarning();
                account.Actions.Add(new CreateHomeDir());
                account.OK = false;
            }
        }
    }
}
