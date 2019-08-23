using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class MoveToSmartschoolClassGroup : AccountAction
    {
        public MoveToSmartschoolClassGroup() : base(
            AccountActionType.MoveSmartschoolClassGroup,
            "Wijzig Klas in Smartschool",
            "De klas van dit account komt niet overeen met de klas in Wisa",
            true, true)
        {

        }

        public async override Task Apply(LinkedAccount linkedAccount)
        {
            var group = AccountApi.Smartschool.GroupManager.Root.Find(linkedAccount.wisaAccount.ClassGroup);
            await Move(linkedAccount, group);           
        }

        /// <summary>
        /// Moves the account to the smartschool class. This is a static function because it can also be
        /// called from other actions, like adding the account
        /// </summary>
        /// <param name="linkedAccount"></param>
        /// <returns></returns>
        public static async Task Move(LinkedAccount linkedAccount, AccountApi.IGroup group)
        {
            if (group != null)
            {
                bool result = await AccountApi.Smartschool.GroupManager.MoveUserToClass(linkedAccount.smartschoolAccount, group, linkedAccount.wisaAccount.ClassChange);
                if (result)
                {
                    MainWindow.Instance.Log.AddMessage(AccountApi.Origin.Smartschool, linkedAccount.wisaAccount.FullName + " moved to " + linkedAccount.wisaAccount.ClassGroup);
                }
                else
                {
                    MainWindow.Instance.Log.AddError(AccountApi.Origin.Smartschool, "Failed to move " + linkedAccount.wisaAccount.FullName + " to " + linkedAccount.wisaAccount.ClassGroup);
                }
            }
            else
            {
                MainWindow.Instance.Log.AddError(AccountApi.Origin.Smartschool, "Class " + linkedAccount.wisaAccount.ClassGroup + " does not exist.");
            }
        }
    }
}
