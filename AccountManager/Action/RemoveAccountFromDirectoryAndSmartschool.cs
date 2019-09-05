using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class RemoveAccountFromDirectoryAndSmartschool : AccountAction
    {
        public RemoveAccountFromDirectoryAndSmartschool() : base(
            AccountActionType.RemoveFromDirectoryAndSmartschool,
            "Verwijder dit account",
            "Accounts die niet bestaan in Wisa zijn overbodig",
            true)
        {

        }

        public async override Task Apply(LinkedAccount linkedAccount, DateTime deletionDate)
        {
            await AccountApi.Directory.AccountManager.DeleteStudent(linkedAccount.directoryAccount);
            await AccountApi.Smartschool.AccountManager.UnregisterStudent(linkedAccount.smartschoolAccount, deletionDate);
        }
    }
}
