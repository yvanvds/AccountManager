using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    class MoveDirectoryClassGroup : AccountAction
    {
        public MoveDirectoryClassGroup() : base(
            "Wijzig Klas in Active Directory",
            "De klas van dit account komt niet overeen met de gegevens in Wisa",
            true, true)
        { }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            bool connected = await State.App.Instance.AD.Connect().ConfigureAwait(false);
            if (!connected) return;

            bool result = await AccountApi.Directory.AccountManager.MoveStudentToClass(linkedAccount.Directory.Account, linkedAccount.Wisa.Account.ClassName).ConfigureAwait(false);
            if (result)
            {
                MainWindow.Instance.Log.AddMessage(AccountApi.Origin.Directory, linkedAccount.Wisa.Account.FullName + " moved to " + linkedAccount.Wisa.Account.ClassName);
            }
            else
            {
                MainWindow.Instance.Log.AddError(AccountApi.Origin.Directory, "Failed to move " + linkedAccount.Wisa.Account.FullName + " to " + linkedAccount.Wisa.Account.ClassName);
            }
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (account.Wisa.Account.ClassName != account.Directory.Account.ClassGroup)
            {
                account.Actions.Add(new MoveDirectoryClassGroup());
                account.Directory.FlagWarning();
                account.OK = false;
            }
        }
    }
}
