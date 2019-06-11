using System;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    public class AddClassGroupToDirectory : GroupAction
    {
        public override Task Apply(LinkedGroup linkedGroup)
        {
            throw new NotImplementedException();
        }

        public AddClassGroupToDirectory() : base(
            "Klas toevoegen aan Active Directory",
            "Voeg deze klas toe aan Active Directory.",
            true)
        {

        }
    }
}
