using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class DeleteSmartschoolAccount : AccountAction
    {
        public DeleteSmartschoolAccount(bool allreadyDisabled) : base(AccountActionType.RemoveFromSmartschool,
            "Verwijder dit account uit smartschool",
            "Accounts die niet bestaan in Wisa zijn overbodig." + (allreadyDisabled ? " (Account is al uitgeschakeld)" : ""), true)
        { }

        public async override Task Apply(LinkedAccount linkedAccount, DateTime deletionDate)
        {
            await AccountApi.Smartschool.AccountManager.Delete(linkedAccount.smartschoolAccount, deletionDate);
        }
    }
}
